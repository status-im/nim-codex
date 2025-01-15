import std/os
import std/httpclient
import std/strutils
from std/net import TimeoutError

import pkg/chronos
import ../ethertest
import ./codexprocess
import ./nodeprocess

ethersuite "Node block expiration tests":
  var node: CodexProcess
  var baseurl: string

  let dataDir = getTempDir() / "Codex1"
  let content = "test file content"

  setup:
    baseurl = "http://localhost:8080/api/codex/v1"

  teardown:
    await node.stop()

    dataDir.removeDir()

  proc startTestNode(blockTtlSeconds: int) {.async.} =
    node = await CodexProcess.startNode(
      @[
        "--api-port=8080",
        "--data-dir=" & dataDir,
        "--nat=none",
        "--listen-addrs=/ip4/127.0.0.1/tcp/0",
        "--disc-port=8090",
        "--block-ttl=" & $blockTtlSeconds,
        "--block-mi=1",
        "--block-mn=10",
      ],
      false,
      "cli-test-node",
    )
    await node.waitUntilStarted()

  proc uploadTestFile(): string =
    let client = newHttpClient()
    let uploadUrl = baseurl & "/data"
    let uploadResponse = client.post(uploadUrl, content)
    check uploadResponse.status == "200 OK"
    client.close()
    uploadResponse.body

  proc downloadTestFile(contentId: string, local = false): Response =
    let client = newHttpClient(timeout = 3000)
    let downloadUrl =
      baseurl & "/data/" & contentId & (if local: "" else: "/network/stream")

    let content = client.get(downloadUrl)
    client.close()
    content

  proc hasFile(contentId: string): bool =
    let client = newHttpClient(timeout = 3000)
    let dataLocalUrl = baseurl & "/data/" & contentId
    let content = client.get(dataLocalUrl)
    client.close()
    content.code == Http200

  test "node retains not-expired file":
    await startTestNode(blockTtlSeconds = 10)

    let contentId = uploadTestFile()

    await sleepAsync(2.seconds)

    let response = downloadTestFile(contentId, local = true)
    check:
      hasFile(contentId)
      response.status == "200 OK"
      response.body == content

  test "node deletes expired file":
    await startTestNode(blockTtlSeconds = 1)

    let contentId = uploadTestFile()

    await sleepAsync(3.seconds)

    check:
      not hasFile(contentId)
      downloadTestFile(contentId, local = true).code == Http404
