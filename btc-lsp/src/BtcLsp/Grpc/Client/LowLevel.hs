module BtcLsp.Grpc.Client.LowLevel
  ( runUnary,
    GCEnv (..),
    GCPort (..),
  )
where

import BtcLsp.Grpc.Data
import Data.Aeson
  ( FromJSON (..),
    camelTo2,
    defaultOptions,
    fieldLabelModifier,
    genericParseJSON,
    withScientific,
  )
import qualified Data.ByteString.Lazy as BL
import qualified Data.CaseInsensitive as CI
import Data.Coerce (coerce)
import Data.ProtoLens.Service.Types (HasMethod, HasMethodImpl (..))
import Data.Scientific (floatingOrInteger)
import Data.Signable (Signable)
import qualified Data.Signable as Signable
import GHC.TypeLits (Symbol)
import Network.GRPC.Client
import Network.GRPC.Client.Helpers
import Network.GRPC.HTTP2.Encoding (gzip)
import qualified Network.GRPC.HTTP2.ProtoLens as ProtoLens
import Network.HTTP2.Client
import Proto.SignableOrphan ()
import Text.PrettyPrint.GenericPretty
  ( Out,
  )
import Text.PrettyPrint.GenericPretty.Import
  ( inspectPlain,
  )
import Universum

data GCEnv = GCEnv
  { gcEnvHost :: String,
    gcEnvPort :: GCPort,
    gcEnvPrvKey :: PrvKey 'Client,
    gcEnvPubKey :: PubKey 'Server,
    gcEnvSigHeaderName :: SigHeaderName
  }
  deriving (Eq, Generic)

instance FromJSON GCEnv where
  parseJSON =
    genericParseJSON
      defaultOptions
        { fieldLabelModifier = camelTo2 '_' . drop 5
        }

newtype GCPort
  = GCPort PortNumber
  deriving
    ( Enum,
      Eq,
      Integral,
      Num,
      Ord,
      Read,
      Real,
      Show
    )

instance FromJSON GCPort where
  parseJSON =
    withScientific "GCPort" $ \x0 ->
      case floatingOrInteger x0 of
        Left (_ :: Double) -> fail "Non-integer"
        Right x -> pure x

runUnary ::
  ( Out res,
    Show res,
    Signable res,
    Signable req,
    HasMethod s m,
    req ~ MethodInput s m,
    res ~ MethodOutput s m
  ) =>
  ProtoLens.RPC s (m :: Symbol) ->
  GCEnv ->
  (res -> ByteString -> IO Bool) ->
  req ->
  IO (Either Text res)
runUnary rpc env verifySig req = do
  res <-
    runClientIO $
      bracket
        (makeClient env req True True)
        close
        (\grpc -> rawUnary rpc grpc req)
  case res of
    Right (Right (Right (h, mh, Right x))) ->
      case find (\header -> fst header == sigHeaderName) $ h <> fromMaybe mempty mh of
        Nothing ->
          pure . Left $
            "Client ==> missing server header "
              <> inspectPlain sigHeaderName
        Just (_, rawSig) -> do
          isVerified <- verifySig x rawSig
          pure $
            if isVerified
              then Right x
              else
                Left $
                  "Client ==> server signature verification failed for raw bytes "
                    <> (inspectPlain . BL.toStrict $ Signable.toBinary x)
                    <> " from decoded payload "
                    <> inspectPlain x
                    <> " with signature "
                    <> inspectPlain rawSig
    x ->
      --
      -- TODO : replace show with inspectPlain
      -- need additional instances for this.
      --
      pure . Left $
        "Client ==> server grpc failure "
          <> show x
  where
    sigHeaderName = CI.mk . coerce $ gcEnvSigHeaderName env

makeClient ::
  Signable req =>
  GCEnv ->
  req ->
  UseTlsOrNot ->
  Bool ->
  ClientIO GrpcClient
makeClient env req tlsEnabled doCompress =
  setupGrpcClient $
    (grpcClientConfigSimple (gcEnvHost env) (coerce $ gcEnvPort env) tlsEnabled)
      { _grpcClientConfigCompression = compression,
        _grpcClientConfigHeaders = [(sigHeaderName, signature)]
      }
  where
    sigHeaderName = coerce $ gcEnvSigHeaderName env
    signature = Signable.exportSigDer . coerce $ sign (gcEnvPrvKey env) req
    compression = if doCompress then gzip else uncompressed
