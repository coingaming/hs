{-# LANGUAGE TemplateHaskell #-}

module BtcLsp.Data.Env
  ( Env (..),
    RawConfig (..),
    readRawConfig,
    readGCEnv,
    withEnv,
    parseFromJSON,
  )
where

import BtcLsp.Data.Kind
import BtcLsp.Data.Type
import BtcLsp.Grpc.Client.LowLevel
import BtcLsp.Grpc.Server.LowLevel
import qualified BtcLsp.Grpc.Sig as Sig
import BtcLsp.Import.External
import qualified BtcLsp.Import.Psql as Psql
import qualified BtcLsp.Math.Swap as Math
import BtcLsp.Rpc.Env
import Control.Monad.Logger (runNoLoggingT)
import qualified Data.Aeson as A (decode)
import qualified Data.ByteString as BS
import Data.ByteString.Lazy.Char8 as C8L (pack)
import qualified Env as E
  ( Error (..),
    Mod,
    Var,
    auto,
    def,
    header,
    help,
    keep,
    nonempty,
    parse,
    str,
    var,
  )
import qualified LndClient as Lnd
import qualified LndClient.Data.SignMessage as Lnd
import qualified LndClient.RPC.Katip as Lnd
import qualified Network.Bitcoin as Btc

data Env = Env
  { -- | General
    envSQLPool :: Pool Psql.SqlBackend,
    -- | Logging
    envKatipNS :: Namespace,
    envKatipCTX :: LogContexts,
    envKatipLE :: LogEnv,
    envYesodLog :: YesodLog,
    -- | Lnd
    envLnd :: Lnd.LndEnv,
    envLndP2PHost :: HostName,
    envLndP2PPort :: PortNumber,
    envSwapIntoLnMinAmt :: Money 'Usr 'OnChain 'Fund,
    envMsatPerByte :: Maybe MSat,
    envLndPubKey :: MVar Lnd.NodePubKey,
    -- | Grpc
    envGrpcServer :: GSEnv,
    -- | Elecrts
    envElectrs :: Maybe ElectrsEnv,
    -- | Bitcoind
    envBtc :: Btc.Client
  }

data RawConfig = RawConfig
  { -- | General
    rawConfigLibpqConnStr :: Psql.ConnectionString,
    -- | Logging
    rawConfigLogEnv :: Text,
    rawConfigLogFormat :: LogFormat,
    rawConfigLogVerbosity :: Verbosity,
    rawConfigLogSeverity :: Severity,
    rawConfigLogSecrets :: SecretVision,
    rawConfigLogYesod :: YesodLog,
    -- | Lnd
    rawConfigLndEnv :: Lnd.LndEnv,
    rawConfigLndP2PHost :: HostName,
    rawConfigLndP2PPort :: PortNumber,
    rawConfigMinChanCap :: Money 'Chan 'Ln 'Fund,
    rawConfigMsatPerByte :: Maybe MSat,
    -- | Grpc
    rawConfigGrpcServerEnv :: GSEnv,
    -- | Electrs Rpc
    rawConfigElectrsEnv :: Maybe ElectrsEnv,
    -- | Bitcoind
    rawConfigBtcEnv :: BitcoindEnv
  }

parseFromJSON :: (FromJSON a) => String -> Either E.Error a
parseFromJSON =
  maybe
    (Left $ E.UnreadError "parseFromJSON failed")
    Right
    . A.decode
    . C8L.pack

readRawConfig :: IO RawConfig
readRawConfig =
  E.parse (E.header "BtcLsp") $
    RawConfig
      -- General
      <$> E.var (E.str <=< E.nonempty) "LSP_LIBPQ_CONN_STR" opts
      -- Logging
      <*> E.var (E.str <=< E.nonempty) "LSP_LOG_ENV" opts
      <*> E.var (E.auto <=< E.nonempty) "LSP_LOG_FORMAT" opts
      <*> E.var (E.auto <=< E.nonempty) "LSP_LOG_VERBOSITY" opts
      <*> E.var (E.auto <=< E.nonempty) "LSP_LOG_SEVERITY" opts
      <*> E.var (E.auto <=< E.nonempty) "LSP_LOG_SECRET" (opts <> E.def SecretHidden)
      <*> E.var (E.auto <=< E.nonempty) "LSP_LOG_YESOD" (opts <> E.def YesodLogNoMain)
      -- Lnd
      <*> E.var (parseFromJSON <=< E.nonempty) "LSP_LND_ENV" opts
      <*> E.var (E.str <=< E.nonempty) "LSP_LND_P2P_HOST" opts
      <*> E.var (E.auto <=< E.nonempty) "LSP_LND_P2P_PORT" opts
      <*> E.var (E.auto <=< E.nonempty) "LSP_MIN_CHAN_CAP_MSAT" opts
      <*> optional (E.var (E.auto <=< E.nonempty) "LSP_MSAT_PER_BYTE" opts)
      -- Grpc
      <*> E.var (parseFromJSON <=< E.nonempty) "LSP_GRPC_SERVER_ENV" opts
      -- Electrs
      --
      -- TODO : move into separate package
      --
      <*> optional (E.var (parseFromJSON <=< E.nonempty) "LSP_ELECTRS_ENV" opts)
      -- Bitcoind
      <*> E.var (parseFromJSON <=< E.nonempty) "LSP_BITCOIND_ENV" opts

readGCEnv :: IO GCEnv
readGCEnv =
  E.parse (E.header "GCEnv") $
    E.var (parseFromJSON <=< E.nonempty) "LSP_GRPC_CLIENT_ENV" opts

opts :: E.Mod E.Var a
opts =
  E.keep <> E.help ""

withEnv ::
  forall m a.
  ( MonadUnliftIO m
  ) =>
  RawConfig ->
  (Env -> KatipContextT m a) ->
  m a
withEnv rc this = do
  pubKeyVar <- newEmptyMVar
  handleScribe <-
    liftIO $
      mkHandleScribeWithFormatter
        ( case rawConfigLogFormat rc of
            Bracket -> bracketFormat
            JSON -> jsonFormat
        )
        ColorIfTerminal
        stdout
        (permitItem $ rawConfigLogSeverity rc)
        (rawConfigLogVerbosity rc)
  let newLogEnv =
        liftIO $
          registerScribe
            "stdout"
            handleScribe
            defaultScribeSettings
            =<< initLogEnv
              "BtcLsp"
              ( Environment $ rawConfigLogEnv rc
              )
  let newSqlPool :: m (Pool Psql.SqlBackend) =
        liftIO . runNoLoggingT $
          Psql.createPostgresqlPool (rawConfigLibpqConnStr rc) 10
  let katipCtx = mempty :: LogContexts
  let katipNs = mempty :: Namespace
  let lnd = rawConfigLndEnv rc
  bracket newLogEnv rmLogEnv $ \le ->
    bracket newSqlPool rmSqlPool $ \pool -> do
      let rBtc = rawConfigBtcEnv rc
      btc <-
        liftIO $
          Btc.getClient
            (from $ bitcoindEnvHost rBtc)
            (from $ bitcoindEnvUsername rBtc)
            (from $ bitcoindEnvPassword rBtc)
      runKatipContextT le katipCtx katipNs
        . withUnliftIO
        $ \(UnliftIO run) ->
          run . this $
            Env
              { -- General
                envSQLPool = pool,
                -- Logging
                envKatipLE = le,
                envKatipCTX = katipCtx,
                envKatipNS = katipNs,
                envYesodLog = rawConfigLogYesod rc,
                -- Lnd
                envLnd = lnd,
                envLndP2PHost = rawConfigLndP2PHost rc,
                envLndP2PPort = rawConfigLndP2PPort rc,
                envSwapIntoLnMinAmt =
                  Math.newSwapIntoLnMinAmt $
                    rawConfigMinChanCap rc,
                envMsatPerByte = rawConfigMsatPerByte rc,
                envLndPubKey = pubKeyVar,
                -- Grpc
                envGrpcServer =
                  (rawConfigGrpcServerEnv rc)
                    { gsEnvSigner = run . signT lnd,
                      gsEnvLogger = run . $(logTM) DebugS . logStr
                    },
                envElectrs = rawConfigElectrsEnv rc,
                envBtc = btc
              }
  where
    rmLogEnv :: LogEnv -> m ()
    rmLogEnv = void . liftIO . closeScribes
    rmSqlPool :: Pool Psql.SqlBackend -> m ()
    rmSqlPool = liftIO . destroyAllResources
    signT ::
      Lnd.LndEnv ->
      Sig.MsgToSign ->
      KatipContextT m (Maybe Sig.LndSig)
    signT lnd msg = do
      eSig <-
        Lnd.signMessage lnd $
          Lnd.SignMessageRequest
            { Lnd.message = Sig.unMsgToSign msg,
              Lnd.keyLoc =
                Lnd.KeyLocator
                  { Lnd.keyFamily = 6,
                    Lnd.keyIndex = 0
                  },
              Lnd.doubleHash = False,
              Lnd.compactSig = False
            }
      case eSig of
        Left e -> do
          $(logTM) ErrorS . logStr $
            "Server ==> signing procedure failed "
              <> inspect e
          pure Nothing
        Right sig0 -> do
          let sig = coerce sig0
          $(logTM) DebugS . logStr $
            "Server ==> signing procedure succeeded for msg of "
              <> inspect (BS.length $ Sig.unMsgToSign msg)
              <> " bytes "
              <> inspect msg
              <> " got signature of "
              <> inspect (BS.length sig)
              <> " bytes "
              <> inspect sig
          pure . Just $ Sig.LndSig sig
