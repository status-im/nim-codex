import std/os
import std/macros
import std/httpclient
import ../ethertest
import ./codexclient
import ./nodes

export ethertest
export codexclient
export nodes

template twonodessuite*(name: string, debug1, debug2: bool | string, body) =
  twonodessuite(name, $debug1, $debug2, body)

template twonodessuite*(name: string, debug1, debug2: string, body) =
  ethersuite name:

    var node1 {.inject, used.}: NodeProcess
    var node2 {.inject, used.}: NodeProcess
    var client1 {.inject, used.}: CodexClient
    var client2 {.inject, used.}: CodexClient
    var account1 {.inject, used.}: Address
    var account2 {.inject, used.}: Address

    let dataDir1 = getTempDir() / "Codex1"
    let dataDir2 = getTempDir() / "Codex2"

    setup:
      client1 = CodexClient.new("http://localhost:8080/api/codex/v1")
      client2 = CodexClient.new("http://localhost:8081/api/codex/v1")
      account1 = accounts[0]
      account2 = accounts[1]

      var node1Args = @[
        "--api-port=8080",
        "--data-dir=" & dataDir1,
        "--nat=127.0.0.1",
        "--disc-ip=127.0.0.1",
        "--disc-port=8090",
        "--listen-addrs=/ip4/127.0.0.1/tcp/0",
        "persistence",
        "prover",
        "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs",
        "--circom-wasm=tests/circuits/fixtures/proof_main.wasm",
        "--circom-zkey=tests/circuits/fixtures/proof_main.zkey",
        "--eth-account=" & $account1
      ]

      if debug1 != "true" and debug1 != "false":
        node1Args.add("--log-level=" & debug1)

      node1 = startNode(node1Args, debug = debug1)
      node1.waitUntilStarted()

      let bootstrap = (!client1.info()["spr"]).getStr()

      var node2Args = @[
        "--api-port=8081",
        "--data-dir=" & dataDir2,
        "--nat=127.0.0.1",
        "--disc-ip=127.0.0.1",
        "--disc-port=8091",
        "--listen-addrs=/ip4/127.0.0.1/tcp/0",
        "--bootstrap-node=" & bootstrap,
        "persistence",
        "prover",
        "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs",
        "--circom-wasm=tests/circuits/fixtures/proof_main.wasm",
        "--circom-zkey=tests/circuits/fixtures/proof_main.zkey",
        "--eth-account=" & $account2
      ]

      if debug2 != "true" and debug2 != "false":
        node2Args.add("--log-level=" & debug2)

      node2 = startNode(node2Args, debug = debug2)
      node2.waitUntilStarted()

      # ensure that we have a recent block with a fresh timestamp
      discard await send(ethProvider, "evm_mine")

    teardown:
      client1.close()
      client2.close()

      node1.stop()
      node2.stop()

      removeDir(dataDir1)
      removeDir(dataDir2)

    body
