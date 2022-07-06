{-# LANGUAGE TemplateHaskell #-}

module BtcLsp.Thread.LnChanOpener
  ( apply,
  )
where

import BtcLsp.Import
import qualified BtcLsp.Import.Psql as Psql
import qualified BtcLsp.Storage.Model.LnChan as LnChan
import qualified BtcLsp.Storage.Model.SwapIntoLn as SwapIntoLn
import qualified BtcLsp.Storage.Model.SwapUtxo as SwapUtxo
import qualified Data.Set as Set
import qualified LndClient.Data.ChannelPoint as ChannelPoint
import qualified LndClient.Data.Peer as Peer
import qualified LndClient.RPC.Silent as LndSilent
import BtcLsp.Psbt.Utils (swapUtxoToPsbtUtxo)
import qualified BtcLsp.Psbt.PsbtOpener as PO

apply :: (Env m) => m ()
apply =
  forever $ do
    ePeerList <-
      withLnd LndSilent.listPeers id
    whenLeft ePeerList $
      $(logTM) ErrorS
        . logStr
        . ("ListPeers procedure failed: " <>)
        . inspect
    let peerSet =
          Set.fromList $
            Peer.pubKey <$> fromRight [] ePeerList
    runSql $ do
      swaps <-
        filter
          ( \x ->
              Set.member
                (userNodePubKey . entityVal $ snd x)
                peerSet
          )
          <$> SwapIntoLn.getSwapsWaitingPeerSql
      mapM_
        (uncurry openChanSql)
        swaps
    sleep300ms

--
-- TODO : Do not open channel in case where
-- there not is enough liquidity to perform swap.
-- Maybe also put some limits into amount of
-- opening chans per user.
--
openChanSql ::
  ( Env m
  ) =>
  Entity SwapIntoLn ->
  Entity User ->
  ReaderT Psql.SqlBackend m ()
openChanSql (Entity swapKey _) userEnt = do
  res <-
    SwapIntoLn.withLockedRowSql swapKey (== SwapWaitingPeer) $
      \swapVal -> do
        utxos <- SwapUtxo.getSpendableUtxosBySwapIdSql swapKey
        cpEither <- lift . runExceptT $ do
          r <- PO.openChannelPsbt
            (swapUtxoToPsbtUtxo . entityVal <$> utxos)
            (userNodePubKey $ entityVal userEnt)
            (coerce $ swapIntoLnLspFeeAndChangeAddress swapVal)
            (coerce swapIntoLnFeeLsp swapVal)
            Nothing
            (swapIntoLnPrivacy swapVal)
          liftIO (wait $ PO.fundAsync r) >>= except
        either
          ( $(logTM) ErrorS . logStr
              . ("OpenChan procedure failed: " <>)
              . inspect
          )
          ( \cp ->
              LnChan.createUpdateSql
                swapKey
                (ChannelPoint.fundingTxId cp)
                (ChannelPoint.outputIndex cp)
                >> SwapIntoLn.updateWaitingChanSql swapKey
                >> SwapUtxo.updateSpentChanSql swapKey
                >> SwapUtxo.updateSpentChanSwappedSql swapKey
          )
          cpEither
  whenLeft res $
    $(logTM) ErrorS
      . logStr
      . ("Channel opening failed due to wrong status " <>)
      . inspect
