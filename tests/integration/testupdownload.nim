import pkg/codex/rest/json
import ./twonodes

twonodessuite "Uploads and downloads", debug1 = false, debug2 = false:

  test "node allows local file downloads":
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = client1.upload(content1).get
    let cid2 = client2.upload(content2).get

    let resp1 = client1.download(cid1, local = true).get
    let resp2 = client2.download(cid2, local = true).get

    check:
      content1 == resp1
      content2 == resp2

  test "node allows remote file downloads":
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = client1.upload(content1).get
    let cid2 = client2.upload(content2).get

    let resp2 = client1.download(cid2, local = false).get
    let resp1 = client2.download(cid1, local = false).get

    check:
      content1 == resp1
      content2 == resp2

  test "node fails retrieving non-existing local file":
    let content1 = "some file contents"
    let cid1 = client1.upload(content1).get # upload to first node
    let resp2 = client2.download(cid1, local = true) # try retrieving from second node

    check:
      resp2.error.msg == "404 Not Found"

  proc checkRestContent(content: ?!string) =
    let c = content.tryGet()
    # tried to JSON (very easy) and checking the resulting object (would be much nicer)
    # spent an hour to try and make it work.
    check:
      c == "{\"cid\":\"zDvZRwzm1ePSzKSXt57D5YxHwcSDmsCyYN65wW4HT7fuX9HrzFXy\",\"manifest\":{\"treeCid\":\"zDzSvJTezk7bJNQqFq8k1iHXY84psNuUfZVusA5bBQQUSuyzDSVL\",\"datasetSize\":18,\"blockSize\":65536,\"protected\":false}}"

  test "node allows downloading only manifest":
    let content1 = "some file contents"
    let cid1 = client1.upload(content1).get
    let resp2 = client2.downloadManifestOnly(cid1)
    checkRestContent(resp2)

  test "node allows downloading content without stream":
    let content1 = "some file contents"
    let cid1 = client1.upload(content1).get
    let resp1 = client2.downloadNoStream(cid1)
    checkRestContent(resp1)
    let resp2 = client2.download(cid1, local = true).get
    check:
      content1 == resp2
