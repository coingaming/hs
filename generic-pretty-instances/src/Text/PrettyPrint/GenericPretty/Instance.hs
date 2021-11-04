{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Text.PrettyPrint.GenericPretty.Instance
  (
  )
where

import qualified Control.Exception as Exception
import Data.ByteString.Base16 as B16 (encode)
import qualified Data.Fixed as Fixed
import qualified Data.ProtoLens.Runtime.Data.ProtoLens.Encoding.Wire as Wire
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Time.Calendar as Calendar
import Data.Time.Clock (UTCTime)
import qualified Data.Time.LocalTime as LocalTime
import qualified Data.Vector.Unboxed as Unboxed
import qualified Database.Persist as Psql
import qualified Text.Pretty.Simple as PrettySimple
import Text.PrettyPrint.GenericPretty
import Universum

deriving stock instance Generic Wire.Tag

instance Out Wire.Tag

deriving stock instance Generic Wire.WireValue

instance Out Wire.WireValue

deriving stock instance Generic Wire.TaggedValue

instance Out Wire.TaggedValue

deriving stock instance Generic Exception.BlockedIndefinitelyOnMVar

instance Out Exception.BlockedIndefinitelyOnMVar

deriving stock instance Generic Calendar.Day

instance Out Calendar.Day

deriving stock instance Generic LocalTime.TimeOfDay

instance Out LocalTime.TimeOfDay

deriving stock instance Generic (Fixed.Fixed a)

instance Out (Fixed.Fixed a)

deriving stock instance Generic Psql.PersistValue

instance Out Psql.PersistValue

deriving stock instance Generic Psql.LiteralType

instance Out Psql.LiteralType

instance Out Word32 where
  docPrec n = docPrec n . fromIntegral @Word32 @Integer
  doc = doc . fromIntegral @Word32 @Integer

instance Out Word64 where
  docPrec n = docPrec n . fromIntegral @Word64 @Integer
  doc = doc . fromIntegral @Word64 @Integer

instance Out Int32 where
  docPrec n = docPrec n . fromIntegral @Int32 @Integer
  doc = doc . fromIntegral @Int32 @Integer

instance Out Int64 where
  docPrec n = docPrec n . fromIntegral @Int64 @Integer
  doc = doc . fromIntegral @Int64 @Integer

instance Out ByteString where
  docPrec n = docPrec n . newBsDoc
  doc = doc . newBsDoc

instance Out Text where
  docPrec n = docPrec n . T.unpack
  doc = doc . T.unpack

instance Out TL.Text where
  docPrec n = docPrec n . TL.unpack
  doc = doc . TL.unpack

instance (Out a) => Out (Vector a) where
  docPrec n = docPrec n . toList
  doc = doc . toList

instance
  (Out a, Unboxed.Unbox a) =>
  Out (Unboxed.Vector a)
  where
  docPrec n = docPrec n . Unboxed.toList
  doc = doc . Unboxed.toList

--
-- TODO : proper instance
--
instance (Show a, Show b) => Out (Map a b) where
  docPrec n = docPrec n . PrettySimple.pShow
  doc = doc . TL.unpack . PrettySimple.pShow

instance Out UTCTime where
  docPrec = const Universum.show
  doc = Universum.show

instance (Psql.PersistEntity a) => Out (Psql.Key a) where
  docPrec = const Universum.show
  doc = Universum.show

--
-- Misc
--

data ByteStringDoc
  = ByteStringUtf8 Text
  | ByteStringHex Text
  | ByteStringRaw Text
  deriving stock (Generic)

instance Out ByteStringDoc

newBsDoc :: ByteString -> ByteStringDoc
newBsDoc bs =
  case decodeUtf8' bs of
    Right txt -> ByteStringUtf8 txt
    Left {} ->
      case decodeUtf8' $ B16.encode bs of
        Right txt -> ByteStringHex txt
        Left {} -> ByteStringRaw $ Universum.show bs
