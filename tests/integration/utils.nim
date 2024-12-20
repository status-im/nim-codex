import pkg/chronos
import pkg/codex/logutils

proc nextFreePort*(startPort: int): Future[int] {.async: (raises:[CancelledError]).} =

  proc client(server: StreamServer, transp: StreamTransport) {.async.} =
    await transp.closeWait()

  var port = startPort
  while true:
    trace "checking if port is free", port
    try:
      let host = initTAddress("127.0.0.1", port)
      # We use ReuseAddr here only to be able to reuse the same IP/Port when
      # there's a TIME_WAIT socket. It's useful when running the test multiple
      # times or if a test ran previously using the same port.
      var server = createStreamServer(host, client, {ReuseAddr})
      trace "port is free", port
      await server.closeWait()
      return port
    except TransportOsError:
      trace "port is not free", port
      inc port
    except TransportAddressError:
      raiseAssert "bad address"