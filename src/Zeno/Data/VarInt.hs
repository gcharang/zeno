
module Zeno.Data.VarInt where

import Control.Monad
import Data.Aeson
import Data.Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.RLP
import Data.Serialize
import Data.Word
import Text.Printf
import Network.Ethereum.Data.Utils
import qualified Haskoin as H


newtype VarInt = VarInt { unVarInt :: Word64 }
  deriving (Eq, Ord, Num, ToJSON, FromJSON, PrintfArg)
  deriving Serialize via H.VarInt
  deriving Show via Word64


newtype VarPrefixedList a = VarPrefixedList [a]

instance Serialize a => Serialize (VarPrefixedList a) where
  put (VarPrefixedList xs) = do
    put $ VarInt $ fromIntegral $ length xs
    mapM_ put xs
  get = do
    VarInt n <- get
    VarPrefixedList <$> replicateM (fromIntegral n) get


newtype VarPrefixedLazyByteString = VarPrefixedLazyByteString BSL.ByteString

instance Serialize VarPrefixedLazyByteString where
  put (VarPrefixedLazyByteString bs) = do
    put $ VarInt $ fromIntegral $ BSL.length bs
    putLazyByteString bs
  get = do
    n <- fromIntegral . unVarInt <$> get
    VarPrefixedLazyByteString <$> getLazyByteString n



newtype PackedInteger = PackedInteger Integer
  deriving (Eq, Ord, Bits, Integral, Real, Enum, Num, Show, RLPEncodable, ToJSON, FromJSON)

instance Serialize PackedInteger where
  put = putPacked
  get = getPacked


putPacked :: Integral i => i -> Put
putPacked i = do
  let bs = packInteger $ fromIntegral i
  put (fromIntegral $ BS.length bs :: VarInt)
  putByteString bs

getPacked :: Integral i => Get i
getPacked = do
  len <- fromIntegral . unVarInt <$> get
  fromIntegral . unpackInteger <$> getByteString len
