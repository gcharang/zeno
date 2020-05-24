
module Zeno.Process
  ( AsyncProcess(..)
  , Receiver
  , RemoteReceiver
  , RemoteMessage(..)
  , Process
  , ProcessId(..) -- This is a misnomer, it refers to remote process IDs. Should be topic.
  , NodeId(..)
  , Node
  , monitorRemote
  , receiveDuringS
  , receiveMaybe
  , receiveTimeout
  , receiveWait
  , send
  , sendSTM
  , sendRemote
  , hashServiceId
  , spawn
  , startNode
  , stopNode
  , subscribe
  , withRemoteMessage
  ) where

import Crypto.Hash
import qualified Data.ByteString as BS
import qualified Data.ByteArray as BA
import Data.Time.Clock

import UnliftIO
import UnliftIO.Async
import UnliftIO.STM

import Zeno.Prelude
import Zeno.Process.Types
import Zeno.Process.Remote
import Zeno.Process.Node
import Zeno.Data.Misc


type MonadBase m = (MonadUnliftIO m, MonadResource m, MonadLogger m)


spawn :: forall i m b. MonadBase m => String -> (AsyncProcess i b -> m b) -> m (AsyncProcess i b)
spawn threadName forked = do
  handoff <- newEmptyMVar
  procMbox <- newEmptyTMVarIO
  UnliftIO unliftIO <- askUnliftIO

  let
    debugThreads = False

    runThread = do
      when debugThreads do
        traceM $ emot emSnout ++ " : " ++ threadName
        atomically (modifyTVar globalThreadCount (+1))
      async do
        unliftIO do
          catchAny
            (readMVar handoff >>= forked)
            logThreadDied

    stopThread asnc = do
      cancel asnc
      when debugThreads do
        traceM $ emot emFrogFace ++ " : " ++ threadName
        atomically (modifyTVar globalThreadCount (+(-1)))
        readTVarIO globalThreadCount >>= print

  (_, procAsync) <- allocate runThread stopThread
  let proc = Process{..}
  putMVar handoff proc
  pure proc

  where

  logThreadDied :: SomeException -> m a
  logThreadDied e = do
    logError $ "Thread died with: " ++ show e
    throwIO e


globalThreadCount :: TVar Int
globalThreadCount = unsafePerformIO $ newTVarIO 0


send :: MonadIO m => AsyncProcess i b -> i -> m ()
send proc i = atomically $ sendSTM proc i

sendSTM :: AsyncProcess i b -> i -> STM ()
sendSTM Process{..} = putTMVar procMbox

receiveWait :: (HasReceive r i, MonadBase m) => r -> m i
receiveWait = atomically . receiveSTM

receiveMaybe :: (MonadBase m, Typeable i, HasReceive r i) => r -> m (Maybe i)
receiveMaybe = atomically . receiveMaybeSTM

receiveTimeout :: (MonadBase m, HasReceive r i) => r -> Int -> m (Maybe i)
receiveTimeout recv us = do
  delay <- registerDelay us
  atomically do
    receiveMaybeSTM recv >>=
      \case
        Just o -> pure (Just o)
        Nothing -> do
          readTVar delay >>= checkSTM
          pure Nothing


receiveTimeoutS :: (MonadBase m, Typeable i) => Receiver i -> Int -> m (Maybe i)
receiveTimeoutS recv = receiveTimeout recv . (* second)


receiveDuring :: (MonadBase m, Typeable i) => Receiver i -> Int -> (i -> m ()) -> m ()
receiveDuring recv timeout act = do
  startTime <- liftIO $ getCurrentTime
  fix $ \f -> do
    d <- liftIO $ timeDelta startTime
    let us = timeout - d
    receiveTimeout recv us >>= mapM_ act
    when (us > 0) f

receiveDuringS :: (MonadBase m, Typeable i) => Receiver i -> Int -> (i -> m ()) -> m ()
receiveDuringS recv = receiveDuring recv . (* second)
  
second :: Num i => i
second = 1000000

blake2b_160 :: BS.ByteString -> BS.ByteString
blake2b_160 b = BS.pack (BA.unpack (hash b :: Digest Blake2b_160))

hashServiceId :: BS.ByteString -> ProcessId
hashServiceId = ProcessId . toFixed . blake2b_160

timeDelta :: MonadIO m => UTCTime -> m Int
timeDelta t = f <$> liftIO getCurrentTime where
  f now = round . (* second) . realToFrac $ diffUTCTime now t


(<&>) :: Functor f => f a -> (a -> b) -> f b
(<&>) = flip fmap
infixl 1 <&>