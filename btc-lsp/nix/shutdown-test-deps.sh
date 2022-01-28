#!/bin/sh

THIS_DIR="$(dirname "$(realpath "$0")")"
ELECTRS_DIR="$THIS_DIR/../.electrs"

. ./nix/export-test-envs.sh

bitcoin_pid=`cat $BTCD_DIR/regtest/bitcoind.pid`
lnd_lsp_pid=`cat $LND_LSP_DIR/lnd.pid`
lnd_alice_pid=`cat $LND_ALICE_DIR/lnd.pid`
electrs_pid=`cat $ELECTRS_DIR/electrs.pid`

kill -9 "$electrs_pid" && true
lncli-lsp stop
lncli-alice stop
timeout 5 bitcoin-cli stop
timeout 5 pg_ctl -D $PGDATA stop
kill -9 "$lnd_lsp_pid" && true
kill -9 "$lnd_alice_pid" && true
kill -9 "$bitcoin_pid" && true
