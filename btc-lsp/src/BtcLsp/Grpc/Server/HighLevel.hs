{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module BtcLsp.Grpc.Server.HighLevel
  ( swapIntoLn,
    swapIntoLnT,
    getCfg,
  )
where

import qualified BtcLsp.Data.Smart as Smart
import BtcLsp.Import
import qualified BtcLsp.Math.Swap as Math
import qualified BtcLsp.Storage.Model.SwapIntoLn as SwapIntoLn
import qualified LndClient.Data.NewAddress as Lnd
import qualified LndClient.Data.PayReq as Lnd
import qualified LndClient.RPC.Katip as Lnd
import qualified Proto.BtcLsp.Data.HighLevel as Grpc
import qualified Proto.BtcLsp.Data.HighLevel_Fields as Grpc
import qualified Proto.BtcLsp.Method.GetCfg as GetCfg
import qualified Proto.BtcLsp.Method.GetCfg_Fields as GetCfg
import qualified Proto.BtcLsp.Method.SwapIntoLn as SwapIntoLn
import qualified Proto.BtcLsp.Method.SwapIntoLn_Fields as SwapIntoLn

swapIntoLn ::
  ( Env m
  ) =>
  Entity User ->
  SwapIntoLn.Request ->
  m SwapIntoLn.Response
swapIntoLn userEnt req = do
  f_loc <- liftIO $ getFieldLocation @SwapIntoLn.Request ["fund_ln_invoice"]
  res <- runExceptT $ do
    fundInv <- fromReqT @Grpc.FundLnInvoice @(LnInvoice 'Fund) f_loc (req ^. SwapIntoLn.maybe'fundLnInvoice)
    privacy <-
      fromReqT
        $( mkFieldLocation
             @SwapIntoLn.Request
             [ "privacy"
             ]
         )
        $ req ^? SwapIntoLn.privacy
    fundInvLnd <- withLndServerT Lnd.decodePayReq ($ from fundInv)
    unsafeRefundAddr <-
      fromReqT
        $( mkFieldLocation
             @SwapIntoLn.Request
             [ "refund_on_chain_address"
             ]
         )
        $ req ^. SwapIntoLn.maybe'refundOnChainAddress
    swapIntoLnT
      userEnt
      fundInvLnd
      unsafeRefundAddr
      privacy
  pure $ case res of
    Left e -> e
    Right (Entity _ swap) ->
      defMessage
        & SwapIntoLn.success
          .~ ( defMessage
                 & SwapIntoLn.fundOnChainAddress
                   .~ from (swapIntoLnFundAddress swap)
                 & SwapIntoLn.minFundMoney
                   .~ from @MSat
                     ( from (swapIntoLnChanCapUser swap)
                         + from (swapIntoLnFeeLsp swap)
                     )
             )

swapIntoLnT ::
  ( Env m
  ) =>
  Entity User ->
  Lnd.PayReq ->
  UnsafeOnChainAddress 'Refund ->
  Privacy ->
  ExceptT SwapIntoLn.Response m (Entity SwapIntoLn)
swapIntoLnT userEnt fundInvLnd unsafeRefundAddr chanPrivacy = do
  --
  -- TODO : Do not fail immediately, but collect
  -- all the input failures.
  --
  when
    ( Lnd.destination fundInvLnd
        /= userNodePubKey (entityVal userEnt)
    )
    $ throwSpec
      SwapIntoLn.Response'Failure'FUND_LN_INVOICE_SIGNATURE_IS_NOT_GENUINE
  refundAddr <-
    withExceptT
      ( \case
          FailureNonSegwitAddr ->
            newSpecFailure SwapIntoLn.Response'Failure'REFUND_ON_CHAIN_ADDRESS_IS_NOT_SEGWIT
          FailureNonValidAddr ->
            newSpecFailure SwapIntoLn.Response'Failure'REFUND_ON_CHAIN_ADDRESS_IS_NOT_VALID
          _ ->
            newInternalFailure defMessage
      )
      $ Smart.newOnChainAddressT unsafeRefundAddr
  fundAddr <-
    from
      <$> withLndServerT
        Lnd.newAddress
        ( $
            Lnd.NewAddressRequest
              { Lnd.addrType = Lnd.WITNESS_PUBKEY_HASH,
                Lnd.account = Nothing
              }
        )
  feeAndChangeAddr <-
    withLndServerT
      Lnd.newAddress
      ( $
          Lnd.NewAddressRequest
            { Lnd.addrType = Lnd.WITNESS_PUBKEY_HASH,
              Lnd.account = Nothing
            }
      )
  lift
    . runSql
    . SwapIntoLn.createIgnoreSql
      userEnt
      fundAddr
      (from feeAndChangeAddr)
      refundAddr
      (Lnd.expiresAt fundInvLnd)
    $ chanPrivacy

getCfg ::
  ( Env m
  ) =>
  Entity User ->
  GetCfg.Request ->
  m GetCfg.Response
getCfg _ _ = do
  pub <- getLspPubKey
  sa <- getLndP2PSocketAddress
  swapMinAmt <- getSwapIntoLnMinAmt
  pure $
    defMessage
      & GetCfg.success
        .~ ( defMessage
               & GetCfg.lspLnNodes
                 .~ [ defMessage
                        & Grpc.pubKey
                          .~ from pub
                        & Grpc.host
                          .~ from (socketAddressHost sa)
                        & Grpc.port
                          .~ from (socketAddressPort sa)
                    ]
               & GetCfg.swapIntoLnMinAmt
                 .~ from swapMinAmt
               & GetCfg.swapIntoLnMaxAmt
                 .~ from Math.swapLnMaxAmt
               & GetCfg.swapFromLnMinAmt
                 .~ from swapMinAmt
               & GetCfg.swapFromLnMaxAmt
                 .~ from Math.swapLnMaxAmt
               & GetCfg.swapLnFeeRate
                 .~ from Math.swapLnFeeRate
               & GetCfg.swapLnMinFee
                 .~ from Math.swapLnMinFee
           )
