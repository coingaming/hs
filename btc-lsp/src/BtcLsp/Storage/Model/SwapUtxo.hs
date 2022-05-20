module BtcLsp.Storage.Model.SwapUtxo
  ( createManySql,
    getSpendableUtxosBySwapIdSql,
    updateUnspentChanReserveSql,
    markRefundedSql,
    markOrphanBlocksSql,
    getUtxosForRefundSql,
    getUtxosBySwapIdSql,
  )
where

import BtcLsp.Import hiding (Storage (..))
import qualified BtcLsp.Import.Psql as Psql

createManySql ::
  ( MonadIO m
  ) =>
  [SwapUtxo] ->
  ReaderT Psql.SqlBackend m ()
createManySql us =
  Psql.upsertManyWhere
    us
    [Psql.copyField SwapUtxoUpdatedAt]
    mempty
    mempty

getSpendableUtxosBySwapIdSql ::
  ( MonadIO m
  ) =>
  SwapIntoLnId ->
  ReaderT Psql.SqlBackend m [Entity SwapUtxo]
getSpendableUtxosBySwapIdSql swapId = do
  Psql.select $
    Psql.from $ \row -> do
      Psql.where_
        ( ( row Psql.^. SwapUtxoSwapIntoLnId
              Psql.==. Psql.val swapId
          )
            Psql.&&. ( row Psql.^. SwapUtxoStatus
                         `Psql.in_` Psql.valList
                           [ SwapUtxoUnspent,
                             SwapUtxoUnspentChanReserve
                           ]
                     )
        )
      pure row

updateUnspentChanReserveSql ::
  ( MonadIO m
  ) =>
  [SwapUtxoId] ->
  ReaderT Psql.SqlBackend m RowQty
updateUnspentChanReserveSql ids = do
  ct <- getCurrentTime
  from <<$>> Psql.updateCount $ \row -> do
    Psql.set
      row
      [ SwapUtxoStatus
          Psql.=. Psql.val SwapUtxoUnspentChanReserve,
        SwapUtxoUpdatedAt
          Psql.=. Psql.val ct
      ]
    Psql.where_ $
      ( row Psql.^. SwapUtxoId
          `Psql.in_` Psql.valList ids
      )
        Psql.&&. ( row Psql.^. SwapUtxoStatus
                     `Psql.in_` Psql.valList
                       [ SwapUtxoUnspent,
                         SwapUtxoUnspentChanReserve
                       ]
                 )

markRefundedSql ::
  ( MonadIO m
  ) =>
  [SwapUtxoId] ->
  TxId 'Funding ->
  ReaderT Psql.SqlBackend m ()
markRefundedSql ids rTxId = do
  ct <- getCurrentTime
  Psql.update $ \row -> do
    Psql.set
      row
      [ SwapUtxoStatus Psql.=. Psql.val SwapUtxoSpentRefund,
        SwapUtxoRefundTxId Psql.=. Psql.val (Just rTxId),
        SwapUtxoUpdatedAt Psql.=. Psql.val ct
      ]
    Psql.where_ $
      ( row Psql.^. SwapUtxoId
          `Psql.in_` Psql.valList ids
      )
        Psql.&&. ( row Psql.^. SwapUtxoStatus
                     `Psql.in_` Psql.valList
                       [ SwapUtxoUnspent,
                         SwapUtxoUnspentChanReserve
                       ]
                 )

getUtxosForRefundSql ::
  ( MonadIO m
  ) =>
  ReaderT
    Psql.SqlBackend
    m
    [(Entity SwapUtxo, Entity SwapIntoLn)]
getUtxosForRefundSql =
  Psql.select $
    Psql.from $ \(swap `Psql.InnerJoin` utxo) -> do
      Psql.on
        ( (swap Psql.^. SwapIntoLnId)
            Psql.==. (utxo Psql.^. SwapUtxoSwapIntoLnId)
        )
      Psql.where_
        ( ( ( swap Psql.^. SwapIntoLnStatus
                Psql.==. Psql.val SwapExpired
            )
              Psql.&&. ( utxo Psql.^. SwapUtxoStatus
                           `Psql.in_` Psql.valList
                             [ SwapUtxoUnspent,
                               SwapUtxoUnspentChanReserve
                             ]
                       )
          )
            Psql.||. ( ( swap Psql.^. SwapIntoLnStatus
                           Psql.==. Psql.val SwapSucceeded
                       )
                         Psql.&&. ( utxo Psql.^. SwapUtxoStatus
                                      Psql.==. Psql.val
                                        SwapUtxoUnspent
                                  )
                     )
        )
      pure (utxo, swap)

getUtxosBySwapIdSql ::
  ( MonadIO m
  ) =>
  SwapIntoLnId ->
  ReaderT Psql.SqlBackend m [Entity SwapUtxo]
getUtxosBySwapIdSql swapId = do
  Psql.select $
    Psql.from $ \row -> do
      Psql.where_
        ( row Psql.^. SwapUtxoSwapIntoLnId
            Psql.==. Psql.val swapId
        )
      pure row

markOrphanBlocksSql :: (MonadIO m) => [BlockId] -> ReaderT Psql.SqlBackend m ()
markOrphanBlocksSql ids = do
  ct <- getCurrentTime
  Psql.update $ \row -> do
    Psql.set
      row
      [ SwapUtxoStatus
          Psql.=. Psql.val SwapUtxoOrphan,
        SwapUtxoUpdatedAt
          Psql.=. Psql.val ct
      ]
    Psql.where_ $
      row Psql.^. SwapUtxoBlockId
        `Psql.in_` Psql.valList ids
