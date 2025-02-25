{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Encoding
  ( Encoding (..),
    Tail (..),
    Large (..),
    smpEncodeList,
    smpListP,
  )
where

import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (c2w, w2c)
import Data.Int (Int64)
import qualified Data.List.NonEmpty as L
import Data.Time.Clock.System (SystemTime (..))
import Data.Word (Word16, Word32)
import Network.Transport.Internal (decodeWord16, decodeWord32, encodeWord16, encodeWord32)
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Util ((<$?>))

-- | SMP protocol encoding
class Encoding a where
  {-# MINIMAL smpEncode, (smpDecode | smpP) #-}

  -- | protocol encoding of type (default implementation uses protocol ByteString encoding)
  smpEncode :: a -> ByteString

  -- | decoding of type (default implementation uses parser)
  smpDecode :: ByteString -> Either String a
  smpDecode = parseAll smpP

  -- | protocol parser of type (default implementation parses protocol ByteString encoding)
  smpP :: Parser a
  smpP = smpDecode <$?> smpP

instance Encoding Char where
  smpEncode = B.singleton
  smpP = A.anyChar

instance Encoding Word16 where
  smpEncode = encodeWord16
  smpP = decodeWord16 <$> A.take 2

instance Encoding Word32 where
  smpEncode = encodeWord32
  smpP = decodeWord32 <$> A.take 4

instance Encoding Int64 where
  smpEncode i = w32 (i `shiftR` 32) <> w32 i
  smpP = do
    l <- w32P
    r <- w32P
    pure $ (l `shiftL` 32) .|. r

w32 :: Int64 -> ByteString
w32 = smpEncode @Word32 . fromIntegral

w32P :: Parser Int64
w32P = fromIntegral <$> smpP @Word32

-- ByteStrings are assumed no longer than 255 bytes
instance Encoding ByteString where
  smpEncode s = B.cons (lenEncode $ B.length s) s
  smpP = A.take =<< lenP

lenEncode :: Int -> Char
lenEncode = w2c . fromIntegral

lenP :: Parser Int
lenP = fromIntegral . c2w <$> A.anyChar

instance Encoding a => Encoding (Maybe a) where
  smpEncode s = maybe "0" (("1" <>) . smpEncode) s
  smpP =
    smpP >>= \case
      '0' -> pure Nothing
      '1' -> Just <$> smpP
      _ -> fail "invalid Maybe tag"

newtype Tail = Tail {unTail :: ByteString}

instance Encoding Tail where
  smpEncode = unTail
  smpP = Tail <$> A.takeByteString

-- newtype for encoding/decoding ByteStrings over 255 bytes with 2-bytes length prefix
newtype Large = Large {unLarge :: ByteString}

instance Encoding Large where
  smpEncode (Large s) = smpEncode @Word16 (fromIntegral $ B.length s) <> s
  smpP = do
    len <- fromIntegral <$> smpP @Word16
    Large <$> A.take len

instance Encoding SystemTime where
  smpEncode = smpEncode . systemSeconds
  smpP = MkSystemTime <$> smpP <*> pure 0

-- lists encode/parse as a sequence of items prefixed with list length (as 1 byte)
smpEncodeList :: Encoding a => [a] -> ByteString
smpEncodeList xs = B.cons (lenEncode $ length xs) . B.concat $ map smpEncode xs

smpListP :: Encoding a => Parser [a]
smpListP = (`A.count` smpP) =<< lenP

instance Encoding String where
  smpEncode = smpEncode . B.pack
  smpP = B.unpack <$> smpP

instance Encoding a => Encoding (L.NonEmpty a) where
  smpEncode = smpEncodeList . L.toList
  smpP =
    lenP >>= \case
      0 -> fail "empty list"
      n -> L.fromList <$> A.count n smpP

instance (Encoding a, Encoding b) => Encoding (a, b) where
  smpEncode (a, b) = smpEncode a <> smpEncode b
  smpP = (,) <$> smpP <*> smpP

instance (Encoding a, Encoding b, Encoding c) => Encoding (a, b, c) where
  smpEncode (a, b, c) = smpEncode a <> smpEncode b <> smpEncode c
  smpP = (,,) <$> smpP <*> smpP <*> smpP

instance (Encoding a, Encoding b, Encoding c, Encoding d) => Encoding (a, b, c, d) where
  smpEncode (a, b, c, d) = smpEncode a <> smpEncode b <> smpEncode c <> smpEncode d
  smpP = (,,,) <$> smpP <*> smpP <*> smpP <*> smpP

instance (Encoding a, Encoding b, Encoding c, Encoding d, Encoding e) => Encoding (a, b, c, d, e) where
  smpEncode (a, b, c, d, e) = smpEncode a <> smpEncode b <> smpEncode c <> smpEncode d <> smpEncode e
  smpP = (,,,,) <$> smpP <*> smpP <*> smpP <*> smpP <*> smpP

instance (Encoding a, Encoding b, Encoding c, Encoding d, Encoding e, Encoding f) => Encoding (a, b, c, d, e, f) where
  smpEncode (a, b, c, d, e, f) = smpEncode a <> smpEncode b <> smpEncode c <> smpEncode d <> smpEncode e <> smpEncode f
  smpP = (,,,,,) <$> smpP <*> smpP <*> smpP <*> smpP <*> smpP <*> smpP
