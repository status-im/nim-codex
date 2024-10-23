import std/times
import std/os
import std/json
import std/tempfiles
import pkg/chronos
import pkg/stint
import pkg/questionable
import pkg/questionable/results

import ./asynctest
import ./integration/nodes


suite "Taiko L2 Integration Tests":

  var node1, node2: NodeProcess

  setup:
    doAssert existsEnv("CODEX_ETH_PRIVATE_KEY"), "Key for Taiko account missing"

    node1 = startNode([
      "--data-dir=" & createTempDir("", ""),
      "--api-port=8080",
      "--nat=127.0.0.1",
      "--disc-ip=127.0.0.1",
      "--disc-port=8090",
      "--persistence",
      "--eth-provider=https://rpc.test.taiko.xyz"
    ])
    node1.waitUntilStarted()

    let bootstrap = (!node1.client.info())["spr"].getStr()

    node2 = startNode([
      "--data-dir=" & createTempDir("", ""),
      "--api-port=8081",
      "--nat=127.0.0.1",
      "--disc-ip=127.0.0.1",
      "--disc-port=8091",
      "--bootstrap-node=" & bootstrap,
      "--persistence",
      "--eth-provider=https://rpc.test.taiko.xyz"
    ])
    node2.waitUntilStarted()

  teardown:
    node1.stop()
    node2.stop()
    node1.removeDataDir()
    node2.removeDataDir()

  test "node 1 buys storage from node 2":
    discard node2.client.postAvailability(
      size=0xFFFFF.u256,
      duration=200.u256,
      minPrice=300.u256,
      maxCollateral=300.u256
    )
    let cid = !node1.client.upload("some file contents")

    echo "    - requesting storage, expires in 5 minutes"
    let expiry = getTime().toUnix().uint64 + 5 * 60
    let purchase = !node1.client.requestStorage(
      cid,
      duration=30.u256,
      reward=400.u256,
      proofProbability=3.u256,
      collateral=200.u256,
      expiry=expiry.u256
    )

    echo "    - waiting for request to start, timeout 5 minutes"
    check eventually(node1.client.getPurchase(purchase).?state == success "started", timeout = 5 * 60 * 1000)

    echo "    - waiting for request to finish, timeout 1 minute"
    check eventually(node1.client.getPurchase(purchase).?state == success "finished", timeout = 1 * 60 * 1000)
