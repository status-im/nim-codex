import std/httpclient
import std/sequtils
from pkg/libp2p import `==`
import pkg/codex/units
import ./twonodes
import ../examples

twonodessuite "REST API", debug1 = false, debug2 = false:

  test "nodes can print their peer information":
    check !client1.info() != !client2.info()

  test "nodes can set chronicles log level":
    client1.setLogLevel("DEBUG;TRACE:codex")

  test "node accepts file uploads":
    let cid1 = client1.upload("some file contents").get
    let cid2 = client1.upload("some other contents").get
    check cid1 != cid2

  test "node shows used and available space":
    discard client1.upload("some file contents").get
    discard client1.postAvailability(totalSize=12.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    let space = client1.space().tryGet()
    check:
      space.totalBlocks == 2
      space.quotaMaxBytes == 8589934592.NBytes
      space.quotaUsedBytes == 65592.NBytes
      space.quotaReservedBytes == 12.NBytes

  test "node lists local files":
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = client1.upload(content1).get
    let cid2 = client1.upload(content2).get
    let list = client1.list().get

    check:
      [cid1, cid2].allIt(it in list.content.mapIt(it.cid))

  test "request storage fails for datasets that are too small":
    let cid = client1.upload("some file contents").get
    let response = client1.requestStorageRaw(cid, duration=10.u256, reward=2.u256, proofProbability=3.u256, collateral=200.u256, expiry=9)

    check:
      response.status == "400 Bad Request"
      response.body == "Dataset too small for erasure parameters, need at least "  & $(2*DefaultBlockSize.int) & " bytes"

  test "request storage succeeds for sufficiently sized datasets":
    let data = await RandomChunker.example(blocks=2)
    let cid = client1.upload(data).get
    let response = client1.requestStorageRaw(cid, duration=10.u256, reward=2.u256, proofProbability=3.u256, collateral=200.u256, expiry=9)

    check:
      response.status == "200 OK"

  test "request storage fails if tolerance is zero":
    let data = await RandomChunker.example(blocks=2)
    let cid = client1.upload(data).get
    let duration = 100.u256
    let reward = 2.u256
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateral = 200.u256
    let nodes = 3
    let tolerance = 0

    var responseBefore = client1.requestStorageRaw(cid,
      duration,
      reward,
      proofProbability,
      collateral,
      expiry,
      nodes.uint,
      tolerance.uint)

    check responseBefore.status == "400 Bad Request"
    check responseBefore.body == "Tolerance needs to be bigger then zero"

  test "request storage fails if nodes and tolerance aren't correct":
    let data = await RandomChunker.example(blocks=2)
    let cid = client1.upload(data).get
    let duration = 100.u256
    let reward = 2.u256
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateral = 200.u256
    let ecParams = @[(1, 1), (2, 1), (3, 2), (3, 3)]

    for ecParam in ecParams:
      let (nodes, tolerance) = ecParam

      var responseBefore = client1.requestStorageRaw(cid,
        duration,
        reward,
        proofProbability,
        collateral,
        expiry,
        nodes.uint,
        tolerance.uint)

      check responseBefore.status == "400 Bad Request"
      check responseBefore.body == "Invalid parameters: parameters must satify `1 < (nodes - tolerance) ≥ tolerance`"

  test "request storage fails if tolerance > nodes (underflow protection)":
    let data = await RandomChunker.example(blocks=2)
    let cid = client1.upload(data).get
    let duration = 100.u256
    let reward = 2.u256
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateral = 200.u256
    let ecParams = @[(0, 1), (1, 2), (2, 3)]

    for ecParam in ecParams:
      let (nodes, tolerance) = ecParam

      var responseBefore = client1.requestStorageRaw(cid,
        duration,
        reward,
        proofProbability,
        collateral,
        expiry,
        nodes.uint,
        tolerance.uint)

      check responseBefore.status == "400 Bad Request"
      check responseBefore.body == "Invalid parameters: `tolerance` cannot be greater than `nodes`"

  test "request storage succeeds if nodes and tolerance within range":
    let data = await RandomChunker.example(blocks=2)
    let cid = client1.upload(data).get
    let duration = 100.u256
    let reward = 2.u256
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateral = 200.u256
    let ecParams = @[(3, 1), (5, 2)]

    for ecParam in ecParams:
      let (nodes, tolerance) = ecParam

      var responseBefore = client1.requestStorageRaw(cid,
        duration,
        reward,
        proofProbability,
        collateral,
        expiry,
        nodes.uint,
        tolerance.uint)

      check responseBefore.status == "200 OK"
