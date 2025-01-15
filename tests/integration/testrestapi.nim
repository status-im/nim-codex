import std/httpclient
import std/sequtils
from pkg/libp2p import `==`
import pkg/codex/units
import ./twonodes
import ../examples
import json

twonodessuite "REST API":
  test "nodes can print their peer information", twoNodesConfig:
    check !client1.info() != !client2.info()

  test "nodes can set chronicles log level", twoNodesConfig:
    client1.setLogLevel("DEBUG;TRACE:codex")

  test "node accepts file uploads", twoNodesConfig:
    let cid1 = client1.upload("some file contents").get
    let cid2 = client1.upload("some other contents").get

    check cid1 != cid2

  test "node shows used and available space", twoNodesConfig:
    discard client1.upload("some file contents").get
    discard client1.postAvailability(
      totalSize = 12.u256, duration = 2.u256, minPrice = 3.u256, maxCollateral = 4.u256
    ).get
    let space = client1.space().tryGet()
    check:
      space.totalBlocks == 2
      space.quotaMaxBytes == 8589934592.NBytes
      space.quotaUsedBytes == 65598.NBytes
      space.quotaReservedBytes == 12.NBytes

  test "node lists local files", twoNodesConfig:
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = client1.upload(content1).get
    let cid2 = client1.upload(content2).get
    let list = client1.list().get

    check:
      [cid1, cid2].allIt(it in list.content.mapIt(it.cid))

  test "request storage fails for datasets that are too small", twoNodesConfig:
    let cid = client1.upload("some file contents").get
    let response = client1.requestStorageRaw(
      cid,
      duration = 10.u256,
      reward = 2.u256,
      proofProbability = 3.u256,
      collateral = 200.u256,
      expiry = 9,
    )

    check:
      response.status == "400 Bad Request"
      response.body ==
        "Dataset too small for erasure parameters, need at least " &
        $(2 * DefaultBlockSize.int) & " bytes"

  test "request storage succeeds for sufficiently sized datasets", twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let response = client1.requestStorageRaw(
      cid,
      duration = 10.u256,
      reward = 2.u256,
      proofProbability = 3.u256,
      collateral = 200.u256,
      expiry = 9,
    )

    check:
      response.status == "200 OK"

  test "request storage fails if tolerance is zero", twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let duration = 100.u256
    let reward = 2.u256
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateral = 200.u256
    let nodes = 3
    let tolerance = 0

    var responseBefore = client1.requestStorageRaw(
      cid, duration, reward, proofProbability, collateral, expiry, nodes.uint,
      tolerance.uint,
    )

    check responseBefore.status == "400 Bad Request"
    check responseBefore.body == "Tolerance needs to be bigger then zero"

  test "request storage fails if nodes and tolerance aren't correct", twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let duration = 100.u256
    let reward = 2.u256
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateral = 200.u256
    let ecParams = @[(1, 1), (2, 1), (3, 2), (3, 3)]

    for ecParam in ecParams:
      let (nodes, tolerance) = ecParam

      var responseBefore = client1.requestStorageRaw(
        cid, duration, reward, proofProbability, collateral, expiry, nodes.uint,
        tolerance.uint,
      )

      check responseBefore.status == "400 Bad Request"
      check responseBefore.body ==
        "Invalid parameters: parameters must satify `1 < (nodes - tolerance) ≥ tolerance`"

  test "request storage fails if tolerance > nodes (underflow protection)",
    twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let duration = 100.u256
    let reward = 2.u256
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateral = 200.u256
    let ecParams = @[(0, 1), (1, 2), (2, 3)]

    for ecParam in ecParams:
      let (nodes, tolerance) = ecParam

      var responseBefore = client1.requestStorageRaw(
        cid, duration, reward, proofProbability, collateral, expiry, nodes.uint,
        tolerance.uint,
      )

      check responseBefore.status == "400 Bad Request"
      check responseBefore.body ==
        "Invalid parameters: `tolerance` cannot be greater than `nodes`"

  test "request storage succeeds if nodes and tolerance within range", twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let duration = 100.u256
    let reward = 2.u256
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateral = 200.u256
    let ecParams = @[(3, 1), (5, 2)]

    for ecParam in ecParams:
      let (nodes, tolerance) = ecParam

      var responseBefore = client1.requestStorageRaw(
        cid, duration, reward, proofProbability, collateral, expiry, nodes.uint,
        tolerance.uint,
      )

      check responseBefore.status == "200 OK"

  test "node accepts file uploads with content type", twoNodesConfig:
    let headers = newHttpHeaders({"Content-Type": "text/plain"})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "200 OK"
    check response.body != ""

  test "node accepts file uploads with content disposition", twoNodesConfig:
    let headers =
      newHttpHeaders({"Content-Disposition": "attachment; filename=\"example.txt\""})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "200 OK"
    check response.body != ""

  test "node accepts file uploads with content disposition without filename",
    twoNodesConfig:
    let headers = newHttpHeaders({"Content-Disposition": "attachment"})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "200 OK"
    check response.body != ""

  test "upload fails if content disposition contains bad filename", twoNodesConfig:
    let headers =
      newHttpHeaders({"Content-Disposition": "attachment; filename=\"exam*ple.txt\""})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "422 Unprocessable Entity"
    check response.body == "The filename is not valid."

  test "upload fails if content type is invalid", twoNodesConfig:
    let headers = newHttpHeaders({"Content-Type": "hello/world"})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "422 Unprocessable Entity"
    check response.body == "The MIME type is not valid."

  test "node retrieve the metadata", twoNodesConfig:
    let headers = newHttpHeaders(
      {
        "Content-Type": "text/plain",
        "Content-Disposition": "attachment; filename=\"example.txt\"",
      }
    )
    let uploadResponse = client1.uploadRaw("some file contents", headers)
    let cid = uploadResponse.body
    let listResponse = client1.listRaw()

    let jsonData = parseJson(listResponse.body)

    check jsonData.hasKey("content") == true

    let content = jsonData["content"][0]

    check content.hasKey("manifest") == true

    let manifest = content["manifest"]

    check manifest.hasKey("filename") == true
    check manifest["filename"].getStr() == "example.txt"
    check manifest.hasKey("mimetype") == true
    check manifest["mimetype"].getStr() == "text/plain"
    check manifest.hasKey("uploadedAt") == true
    check manifest["uploadedAt"].getInt() > 0

  test "node set the headers when for download", twoNodesConfig:
    let headers = newHttpHeaders(
      {
        "Content-Disposition": "attachment; filename=\"example.txt\"",
        "Content-Type": "text/plain",
      }
    )

    let uploadResponse = client1.uploadRaw("some file contents", headers)
    let cid = uploadResponse.body

    check uploadResponse.status == "200 OK"

    let response = client1.downloadRaw(cid)

    check response.status == "200 OK"
    check response.headers.hasKey("Content-Type") == true
    check response.headers["Content-Type"] == "text/plain"
    check response.headers.hasKey("Content-Disposition") == true
    check response.headers["Content-Disposition"] ==
      "attachment; filename=\"example.txt\""

    let local = true
    let localResponse = client1.downloadRaw(cid, local)

    check localResponse.status == "200 OK"
    check localResponse.headers.hasKey("Content-Type") == true
    check localResponse.headers["Content-Type"] == "text/plain"
    check localResponse.headers.hasKey("Content-Disposition") == true
    check localResponse.headers["Content-Disposition"] ==
      "attachment; filename=\"example.txt\""
