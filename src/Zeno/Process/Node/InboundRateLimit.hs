
module Zeno.Process.Node.InboundRateLimit
  ( ReceiverMap
  , ClassyAsync
  , classyAsync
  , newReceiverMap
  , inboundConnectionLimit
  , testInboundConnectionLimit
  ) where

import Data.Word
import Control.Monad
import Control.Monad.Catch
import Test.DejaFu
import Test.DejaFu.Conc.Internal.STM

import Control.Monad.Conc.Class
import Control.Concurrent.Classy hiding (wait)
import Control.Concurrent.Classy.Async
import Control.Concurrent.Classy.MVar

import qualified Data.Map as Map
import Debug.Trace


type HostAddress = Word32
type ReceiverMap m = TVar (STM m) (Map.Map HostAddress (Async m ()))
type ClassyAsync = Async IO
classyAsync :: MonadConc m => m a -> m (Async m a)
classyAsync = async

newReceiverMap :: MonadConc m => m (ReceiverMap m)
newReceiverMap = atomically (newTVar mempty)


inboundConnectionLimit
  :: MonadConc m
  => ReceiverMap m
  -> HostAddress
  -> Async m ()
  -> m a
  -> m a
inboundConnectionLimit mreceivers ip asnc act = do
  finally
    do
      r <- atomically do
        lookupAsync ip mreceivers <*
          insertAsync ip asnc mreceivers
      case r of
        Nothing -> pure ()
        Just asnc -> do
          traceM "Killing thread"
          cancel asnc -- Synchronously cancel
          void $ waitCatch asnc
      act
    do
      atomically do
        lookupAsync ip mreceivers >>=
          mapM_ \oasnc -> 
            when (asnc == oasnc) (void $ deleteAsync ip mreceivers)


insertAsync :: MonadConc m => HostAddress -> Async m () -> ReceiverMap m -> STM m ()
insertAsync ip asnc t = do
  modifyTVar t $ Map.insert ip asnc

lookupAsync :: MonadConc m => HostAddress -> ReceiverMap m -> STM m (Maybe (Async m ()))
lookupAsync ip tmap = do
  Map.lookup ip <$> readTVar tmap

deleteAsync :: MonadConc m => HostAddress -> ReceiverMap m -> STM m ()
deleteAsync ip t = modifyTVar t $ Map.delete ip


testInboundConnectionLimit :: Program (WithSetup (ModelTVar IO Integer)) IO ()
testInboundConnectionLimit = withSetup setup \sem -> do

  mreceivers <- atomically (newTVar mempty)

  asyncs <- forM [0..1] \i -> do
      handoff <- newEmptyMVar
      asnc <- async do
        me <- takeMVar handoff
        inboundConnectionLimit mreceivers 0 me do
          finally
            do
               atomically $ modifyTVar sem (+1)
               -- threadDelay 1                                   -- Test breaks if uncommented.
               --                                 https://github.com/barrucadu/dejafu/issues/323
            do atomically (modifyTVar sem (subtract 1))
      putMVar handoff asnc
      pure asnc

  mapM_ waitCatch asyncs

  where
  setup :: Program Basic IO (ModelTVar IO Integer)
  setup = do
    single <- atomically $ newTVar 0
    registerInvariant do
      n <- inspectTVar single
      when (n > 1) $ error "too many threads"
      pure ()
    pure single

data TooManyThreads = TooManyThreads deriving (Show)
instance Exception TooManyThreads

-- testInboundConnectionLimit :: Program (WithSetup (ModelTVar IO Int)) IO Int
-- testInboundConnectionLimit = withSetup setup $ \tvar -> do
--     a <- async (act tvar)
--     b <- async (act tvar)
--     _ <- waitCatch a
--     _ <- waitCatch b
--     atomically $ readTVar tvar
-- 
--   where
--     setup = atomically $ newTVar 0
-- 
--     act tvar = do
--       atomically $ modifyTVar tvar (+1)
--       threadDelay 1
--       atomically (readTVar tvar) >>= traceShowM
--       atomically $ modifyTVar tvar (subtract 1)
