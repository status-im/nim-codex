import pkg/chronos

proc asyncSpawn*(future: Future[void], ignore: type CatchableError) =
  proc ignoringError() {.async.} =
    try:
      await future
    except ignore:
      discard

  asyncSpawn ignoringError()
