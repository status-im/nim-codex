import pkg/stew/byteutils
import pkg/codex/chunker
import pkg/codex/logutils
import pkg/chronos

import ../asynctest
import ./helpers

type
  CrashingStreamWrapper* = ref object of LPStream
    toRaise*: ref CatchableError

method readOnce*(
  self: CrashingStreamWrapper,
  pbytes: pointer,
  nbytes: int
): Future[int] {.async.} =
  raise self.toRaise

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

  proc raiseStreamException(exc: ref CatchableError) {.async.} =
    let stream = CrashingStreamWrapper.new()
    let chunker = LPStreamChunker.new(
      stream = stream,
      chunkSize = 2'nb)

    stream.toRaise = exc
    discard (await chunker.getBytes())

  test "stream should forward LPStreamError":
    expect LPStreamError:
      await raiseStreamException(newException(LPStreamError, "test error"))

  test "stream should catch LPStreamEOFError":
    await raiseStreamException(newException(LPStreamEOFError, "test error"))

  test "stream should forward CancelledError":
    expect CancelledError:
      await raiseStreamException(newException(CancelledError, "test error"))

  test "stream should forward LPStreamError":
    expect LPStreamError:
      await raiseStreamException(newException(LPStreamError, "test error"))

  test "stream should convert other exceptions to defect":
    expect Defect:
      await raiseStreamException(newException(CatchableError, "test error"))
