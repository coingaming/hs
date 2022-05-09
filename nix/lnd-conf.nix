{ port ? 9735
, rpcport ? 10009
, restport ? 8080
, dataDir ? "./tmp"
, macaroonDir
, name
, writeText
, writeShellScriptBin
, symlinkJoin
, runCommand
, openssl
, lnd
}:
let
  lndconf = writeText "lnd.conf" ''
    [Bitcoin]

    bitcoin.active=1
    bitcoin.regtest=1
    bitcoin.node=bitcoind

    [Bitcoind]
    bitcoind.dir=${workDir}/bitcoind_regtest
    bitcoind.rpchost=127.0.0.1
    bitcoind.rpcuser=developer
    bitcoind.rpcpass=developer
    bitcoind.zmqpubrawblock=tcp://127.0.0.1:28332
    bitcoind.zmqpubrawtx=tcp://127.0.0.1:28333

    [protocol]

    protocol.wumbo-channels=true

    [Application Options]

    listen=0.0.0.0:${toString port}
    rpclisten=localhost:${toString rpcport}
    restlisten=0.0.0.0:${toString restport}
    debuglevel=warn,PEER=warn
  '';
  serviceName = "lnd-${name}";
  workDir = "${dataDir}/${serviceName}";
  tlscert = runCommand "LNDTLS"
    {
      buildInputs = [ openssl ];
    } ''
    mkdir $out
    TLS_KEY="tls.key"
    TLS_CERT="tls.cert"

    echo "subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:127.0.0.1,DNS:${serviceName}" > subjectAltName

    openssl ecparam -genkey -name prime256v1 -out "$TLS_KEY"
    openssl req -new -sha256 -key "$TLS_KEY" \
      -out csr.csr -subj "/CN=${serviceName}/O=${serviceName}"
    openssl x509 -req -in csr.csr \
      -sha256 -days 36500 \
      -extfile ./subjectAltName \
      -signkey "$TLS_KEY" -out "$TLS_CERT"
    cp $TLS_KEY $out
    cp $TLS_CERT $out
    rm csr.csr
    rm ./subjectAltName
  '';
  cli = writeShellScriptBin "lncli" ''
    exec ${lnd}/bin/lncli -n regtest --rpcserver 127.0.0.1:${toString rpcport} --lnddir=${workDir} "$@"
  '';
  setup = writeShellScriptBin "setup" ''
    mkdir -p "${workDir}"
    ls -la
    cp -f ${lndconf} ${workDir}/lnd.conf
    cp -f ${tlscert}/* ${workDir}/
    mkdir -p ${workDir}/data/chain/bitcoin/regtest
    cp --no-preserve=mode,ownership ${macaroonDir}/*macaroon* ${workDir}/data/chain/bitcoin/regtest
  '';
  start = writeShellScriptBin "start" ''
    echo $$ > ${workDir}/lnd.pid
    ${lnd}/bin/lnd --lnddir='${workDir}' --bitcoin.defaultchanconfs=1 > '${workDir}/stdout.log' &
    echo "$!" > ${workDir}/lnd.pid
    echo "Lnd ${name} started"
  '';
  stop = writeShellScriptBin "stop" ''
    lnd_pid=`cat ${workDir}/lnd.pid`
    echo "Stoping lnd ${name} $lnd_pid"
    timeout 5 ${cli}/bin/lncli stop
    kill -9 "$lnd_pid"
  '';
  up = writeShellScriptBin "up" ''
    ${setup}/bin/setup
    ${start}/bin/start
  '';
  down = writeShellScriptBin "down" ''
    ${stop}/bin/stop
  '';
in {
  inherit up down;
}
