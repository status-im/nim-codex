
import pkg/asynctest/chronos/unittest
import pkg/stew/byteutils
import pkg/codex/chunker
import pkg/codex/logutils
import pkg/chronos

import ./helpers

asyncchecksuite "Chunking":
  test "should return proper size chunks":
    var offset = 0
    let contents = [1.byte, 2, 3, 4, 5, 6, 7, 8, 9, 0]
    proc reader(data: ChunkBuffer, len: int): Future[int]
      {.gcsafe, async, raises: [Defect].} =

      let read = min(contents.len - offset, len)
      if read == 0:
        return 0

      copyMem(data, unsafeAddr contents[offset], read)
      offset += read
      return read

    let chunker = Chunker.new(
      reader = reader,
      chunkSize = 2'nb)

    check:
      (await chunker.getBytes()) == [1.byte, 2]
      (await chunker.getBytes()) == [3.byte, 4]
      (await chunker.getBytes()) == [5.byte, 6]
      (await chunker.getBytes()) == [7.byte, 8]
      (await chunker.getBytes()) == [9.byte, 0]
      (await chunker.getBytes()) == []
      chunker.offset == offset

  test "should chunk LPStream":
    let stream = BufferStream.new()
    let chunker = LPStreamChunker.new(
      stream = stream,
      chunkSize = 2'nb)

    proc writer() {.async.} =
      for d in [@[1.byte, 2, 3, 4], @[5.byte, 6, 7, 8], @[9.byte, 0]]:
        await stream.pushData(d)
      await stream.pushEof()
      await stream.close()

    let writerFut = writer()
    check:
      (await chunker.getBytes()) == [1.byte, 2]
      (await chunker.getBytes()) == [3.byte, 4]
      (await chunker.getBytes()) == [5.byte, 6]
      (await chunker.getBytes()) == [7.byte, 8]
      (await chunker.getBytes()) == [9.byte, 0]
      (await chunker.getBytes()) == []
      chunker.offset == 10

    await writerFut

  test "should chunk file":
    let
      path = currentSourcePath()
      file = open(path)
      fileChunker = FileChunker.new(file = file, chunkSize = 256'nb, pad = false)

    var data: seq[byte]
    while true:
      let buff = await fileChunker.getBytes()
      if buff.len <= 0:
        break

      check buff.len <= fileChunker.chunkSize.int
      data.add(buff)

    check:
      string.fromBytes(data) == readFile(path)
      fileChunker.offset == data.len

