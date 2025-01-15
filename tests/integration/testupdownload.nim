import pkg/codex/rest/json
import ./twonodes
import ../codex/examples
import json
from pkg/libp2p import Cid, `$`

twonodessuite "Uploads and downloads":
  test "node allows local file downloads", twoNodesConfig:
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = client1.upload(content1).get
    let cid2 = client2.upload(content2).get

    let resp1 = client1.download(cid1, local = true).get
    let resp2 = client2.download(cid2, local = true).get

    check:
      content1 == resp1
      content2 == resp2

  test "node allows remote file downloads", twoNodesConfig:
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = client1.upload(content1).get
    let cid2 = client2.upload(content2).get

    let resp2 = client1.download(cid2, local = false).get
    let resp1 = client2.download(cid1, local = false).get

    check:
      content1 == resp1
      content2 == resp2

  test "node fails retrieving non-existing local file", twoNodesConfig:
    let content1 = "some file contents"
    let cid1 = client1.upload(content1).get # upload to first node
    let resp2 = client2.download(cid1, local = true) # try retrieving from second node

    check:
      resp2.error.msg == "404 Not Found"

  proc checkRestContent(cid: Cid, content: ?!string) =
    let c = content.tryGet()

    # tried to JSON (very easy) and checking the resulting object (would be much nicer)
    # spent an hour to try and make it work.
    let jsonData = parseJson(c)

    check jsonData.hasKey("cid") == true

    check jsonData["cid"].getStr() == $cid
    check jsonData.hasKey("manifest") == true

    let manifest = jsonData["manifest"]

    check manifest.hasKey("treeCid") == true
    check manifest["treeCid"].getStr() ==
      "zDzSvJTezk7bJNQqFq8k1iHXY84psNuUfZVusA5bBQQUSuyzDSVL"
    check manifest.hasKey("datasetSize") == true
    check manifest["datasetSize"].getInt() == 18
    check manifest.hasKey("blockSize") == true
    check manifest["blockSize"].getInt() == 65536
    check manifest.hasKey("protected") == true
    check manifest["protected"].getBool() == false

  test "node allows downloading only manifest", twoNodesConfig:
    let content1 = "some file contents"
    let cid1 = client1.upload(content1).get

    let resp2 = client1.downloadManifestOnly(cid1)
    checkRestContent(cid1, resp2)

  test "node allows downloading content without stream", twoNodesConfig:
    let content1 = "some file contents"
    let cid1 = client1.upload(content1).get

    let resp1 = client2.downloadNoStream(cid1)
    checkRestContent(cid1, resp1)
    let resp2 = client2.download(cid1, local = true).get
    check:
      content1 == resp2

  test "reliable transfer test", twoNodesConfig:
    proc transferTest(a: CodexClient, b: CodexClient) {.async.} =
      let data = await RandomChunker.example(blocks = 8)
      let cid = a.upload(data).get
      let response = b.download(cid).get
      check:
        response == data

    for run in 0 .. 10:
      await transferTest(client1, client2)
      await transferTest(client2, client1)
