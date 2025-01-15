import pkg/chronos
import codex/utils/trackedfutures

import ../../asynctest
import ../helpers

type Module = object
  trackedFutures: TrackedFutures

asyncchecksuite "tracked futures":
  var module: Module

  setup:
    module = Module(trackedFutures: TrackedFutures.new())

  test "starts with zero tracked futures":
    check module.trackedFutures.len == 0

  test "tracks unfinished futures":
    let fut = newFuture[void]("test")
    module.trackedFutures.track(fut)
    check module.trackedFutures.len == 1

  test "does not track completed futures":
    let fut = newFuture[void]("test")
    fut.complete()
    module.trackedFutures.track(fut)
    check eventually module.trackedFutures.len == 0

  test "does not track failed futures":
    let fut = newFuture[void]("test")
    fut.fail((ref CatchableError)(msg: "some error"))
    module.trackedFutures.track(fut)
    check eventually module.trackedFutures.len == 0

  test "does not track cancelled futures":
    let fut = newFuture[void]("test")
    await fut.cancelAndWait()
    module.trackedFutures.track(fut)
    check eventually module.trackedFutures.len == 0

  test "removes tracked future when finished":
    let fut = newFuture[void]("test")
    module.trackedFutures.track(fut)
    fut.complete()
    check eventually module.trackedFutures.len == 0

  test "removes tracked future when cancelled":
    let fut = newFuture[void]("test")
    module.trackedFutures.track(fut)
    await fut.cancelAndWait()
    check eventually module.trackedFutures.len == 0

  test "cancels and removes all tracked futures":
    let fut1 = newFuture[void]("test1")
    let fut2 = newFuture[void]("test2")
    let fut3 = newFuture[void]("test3")
    module.trackedFutures.track(fut1)
    module.trackedFutures.track(fut2)
    module.trackedFutures.track(fut3)
    await module.trackedFutures.cancelTracked()
    check eventually fut1.cancelled
    check eventually fut2.cancelled
    check eventually fut3.cancelled
    check eventually module.trackedFutures.len == 0
