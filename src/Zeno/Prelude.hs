{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DefaultSignatures #-}

-- TODO: Remote Ethereum.Errors

module Zeno.Prelude
  ( module ALL
  , LazyByteString
  , PercentFormat(..)
  , traceE
  , fromHex
  , toHex
  , expandPath
  , fix1
  , fix2
  , timeDelta
  , timeoutSTM
  , timeoutSTMS
  , threadDelayS
  , murphy
  ) where

import Control.Applicative as ALL
import Control.Monad as ALL (forM, forM_, join, when, replicateM, foldM, forever, unless, void)
import Control.Monad.Except as ALL
import Control.Monad.IO.Class as ALL (MonadIO, liftIO)
import Control.Monad.Reader as ALL (ask, asks, local)
import Control.Monad.Trans.Resource as ALL (MonadResource, allocate)
import GHC.Generics as ALL (Generic)
import GHC.Stack (HasCallStack)

import Data.Aeson as ALL (Value)
import Data.Aeson.Quick as ALL ((.?))
import Data.ByteString as ALL (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import Data.ByteString.Lazy as ALL (toStrict, fromStrict)
import qualified Data.ByteString.Lazy as BSL (ByteString)
import Data.ByteString.Short as ALL (ShortByteString, toShort, fromShort)
import Data.Either as ALL (fromRight, partitionEithers)
import Data.Function as ALL (fix)
import Data.Foldable as ALL (toList)
import Data.List as ALL (elemIndex, find, findIndex, sort, sortOn)
import Data.Map as ALL (Map)
import Data.Maybe as ALL
import Data.Monoid as ALL
import Data.Set as ALL (Set)
import Data.Serialize as ALL (Serialize)
import Data.String.Conv as ALL
import Data.String as ALL (IsString, fromString)
import Data.Text as ALL (Text, unpack)
import Data.Text.Encoding as ALL (encodeUtf8, decodeUtf8)
import Data.Time.Clock as ALL (UTCTime, getCurrentTime, diffUTCTime)
import Data.Word as ALL (Word8, Word16, Word32, Word64)

import Lens.Micro.Platform as ALL hiding ((.=), has)

import UnliftIO
import UnliftIO.Concurrent as ALL (threadDelay, forkIO)
import UnliftIO.Exception as ALL
  (Exception, Handler(..), catchAny, finally, throwIO
  , withException, onException, handle, bracket, impureThrow
  , catches, catch
  )

import Zeno.Data.Aeson as ALL (ToJSON(..), FromJSON(..), SerializeAeson(..))
import Zeno.Data.VarInt as ALL
import Data.FixedBytes as ALL
import Zeno.Monad as ALL
import Zeno.Logging as ALL

import Text.Printf as ALL (PrintfArg, printf)

import System.Directory
import System.IO.Unsafe as ALL (unsafePerformIO)

import Debug.Trace as ALL (traceShowId, traceM, traceShowM)

type LazyByteString = BSL.ByteString

traceE :: String -> Zeno r a -> Zeno r a
traceE prefix act = do
  onException act $ logError prefix

fromHex :: ByteString -> ByteString
fromHex bs =
  if BS.take 2 bs == "0x"
     then fromHex $ BS.drop 2 bs
     else let (b,r) = B16.decode bs
           in if r /= "" then error "Invalid hex" else b

toHex :: ByteString -> ByteString
toHex = B16.encode


expandPath :: FilePath -> IO FilePath
expandPath ('~':xs) = (++xs) <$> getHomeDirectory
expandPath p        = pure p


class PercentFormat a where
  (%) :: String -> a -> String
  default (%) :: PrintfArg a => String -> a -> String
  s % a = printf s a

instance PercentFormat String
instance PercentFormat Word32
instance PercentFormat Integer
instance PercentFormat Int


instance (PrintfArg a, PrintfArg b) => PercentFormat (a, b) where
  s % (a, b) = printf s a b

instance (PrintfArg a, PrintfArg b, PrintfArg c) => PercentFormat (a, b, c) where
  s % (a, b, c) = printf s a b c

instance (PrintfArg a, PrintfArg b, PrintfArg c, PrintfArg d) => PercentFormat (a, b, c, d) where
  s % (a, b, c, d) = printf s a b c d


-- `fix` providing a value.
fix1 :: a -> ((a -> b) -> a -> b) -> b
fix1 a f = fix f a

-- `fix` providing two values.
fix2 :: a -> b -> ((a -> b -> c) -> a -> b -> c) -> c
fix2 a b f = fix f a b


timeDelta :: MonadIO m => UTCTime -> m Int
timeDelta t = f <$> liftIO getCurrentTime where
  f now = round . (* 1000000) . toDouble $ diffUTCTime now t

toDouble :: Real i => i -> Double
toDouble = realToFrac

timeoutSTM :: MonadIO m => Int -> STM a -> m (Maybe a)
timeoutSTM us act = do
  delay <- registerDelay us
  atomically do
    (Just <$> act) <|>
      (readTVar delay >>= checkSTM >> pure Nothing)

timeoutSTMS :: MonadIO m => Int -> STM a -> m (Maybe a)
timeoutSTMS sec = timeoutSTM (sec*1000000)


murphy :: HasCallStack => String -> a
murphy s = error $ "Invariant violation: " ++ show s

threadDelayS :: MonadIO m => Int -> m ()
threadDelayS = threadDelay . (*1000000)
