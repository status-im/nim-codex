import pkg/chronos
import pkg/chronos/transports/stream
import pkg/chronos/transports/common
import pkg/chronos/streams/asyncstream
import pkg/codex/streams
import pkg/stew/byteutils

import ../asynctest
import ./helpers

asyncchecksuite "AsyncStreamWrapper":
  let data = "0123456789012345678901234567890123456789"
  let address = initTAddress("127.0.0.1:46001")

  proc serveReadingClient(server: StreamServer, transp: StreamTransport) {.async.} =
    var wstream = newAsyncStreamWriter(transp)
    await wstream.write(data)
    await wstream.finish()
    await wstream.closeWait()
    await transp.closeWait()
    server.stop()
    server.close()

  proc serveWritingClient(buf: pointer, bufLen: int): auto =
    return proc(server: StreamServer, transp: StreamTransport) {.async.} =
      var rstream = newAsyncStreamReader(transp)
      discard await rstream.readOnce(buf, bufLen)
      await rstream.closeWait()
      await transp.closeWait()
      server.stop()
      server.close()

  test "Read all data":
    var server = createStreamServer(address, serveReadingClient, {ReuseAddr})
    server.start()

    var transp = await connect(address)
    var rstream = newAsyncStreamReader(transp)
    var wrapper = AsyncStreamWrapper.new(reader = rstream)
    var buf = newSeq[byte](data.len)

    let readLen = (await wrapper.readOnce(addr buf[0], buf.len))

    await wrapper.closeImpl()
    await transp.closeWait()
    await server.join()

    check rstream.closed()
    check buf.len == readLen
    check data.toBytes == buf

  test "Read not all data":
    var server = createStreamServer(address, serveReadingClient, {ReuseAddr})
    server.start()

    var transp = await connect(address)
    var rstream = newAsyncStreamReader(transp)
    var wrapper = AsyncStreamWrapper.new(reader = rstream)
    var buf = newSeq[byte](data.len div 2)

    let readLen = (await wrapper.readOnce(addr buf[0], buf.len))

    await wrapper.close()
    await transp.closeWait()
    await server.join()

    check rstream.closed()
    check buf.len == readLen
    check data.toBytes[0 .. buf.len - 1] == buf

  test "Write all data":
    var buf = newSeq[byte](data.len)

    var server =
      createStreamServer(address, serveWritingClient(addr buf[0], buf.len), {ReuseAddr})
    server.start()

    var transp = await connect(address)
    var wstream = newAsyncStreamWriter(transp)
    var wrapper = AsyncStreamWrapper.new(writer = wstream)

    await wrapper.write(data.toBytes())

    await wrapper.close()
    await transp.closeWait()
    await server.join()

    check wstream.closed()
    check data.toBytes == buf
