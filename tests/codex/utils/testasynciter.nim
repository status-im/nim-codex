import pkg/questionable
import pkg/chronos
import pkg/codex/utils/asynciter

import ../../asynctest
import ../helpers

asyncchecksuite "Test AsyncIter":
  test "Should be finished":
    let iter = AsyncIter[int].empty()

    check:
      iter.finished == true

  test "Should map each item using `map`":
    let
      iter1 = AsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = map[int, string](
        iter1,
        proc(i: int): Future[string] {.async.} =
          $i,
      )

    var collected: seq[string]

    for fut in iter2:
      collected.add(await fut)

    check:
      collected == @["0", "1", "2", "3", "4"]

  test "Should leave only odd items using `filter`":
    let
      iter1 = AsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = await filter[int](
        iter1,
        proc(i: int): Future[bool] {.async.} =
          (i mod 2) == 1,
      )

    var collected: seq[int]

    for fut in iter2:
      collected.add(await fut)

    check:
      collected == @[1, 3]

  test "Should leave only odd items using `mapFilter`":
    let
      iter1 = AsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = await mapFilter[int, string](
        iter1,
        proc(i: int): Future[?string] {.async.} =
          if (i mod 2) == 1:
            some($i)
          else:
            string.none,
      )

    var collected: seq[string]

    for fut in iter2:
      collected.add(await fut)

    check:
      collected == @["1", "3"]

  test "Should yield all items before err using `map`":
    let
      iter1 = AsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = map[int, string](
        iter1,
        proc(i: int): Future[string] {.async.} =
          if i < 3:
            return $i
          else:
            raise newException(CatchableError, "Some error"),
      )

    var collected: seq[string]

    expect CatchableError:
      for fut in iter2:
        collected.add(await fut)

    check:
      collected == @["0", "1", "2"]
      iter2.finished

  test "Should yield all items before err using `filter`":
    let
      iter1 = AsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = await filter[int](
        iter1,
        proc(i: int): Future[bool] {.async.} =
          if i < 3:
            return true
          else:
            raise newException(CatchableError, "Some error"),
      )

    var collected: seq[int]

    expect CatchableError:
      for fut in iter2:
        collected.add(await fut)

    check:
      collected == @[0, 1, 2]
      iter2.finished

  test "Should yield all items before err using `mapFilter`":
    let
      iter1 = AsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = await mapFilter[int, string](
        iter1,
        proc(i: int): Future[?string] {.async.} =
          if i < 3:
            return some($i)
          else:
            raise newException(CatchableError, "Some error"),
      )

    var collected: seq[string]

    expect CatchableError:
      for fut in iter2:
        collected.add(await fut)

    check:
      collected == @["0", "1", "2"]
      iter2.finished

  test "Should propagate cancellation error immediately":
    let fut = newFuture[?string]("testasynciter")

    let
      iter1 = AsyncIter[int].new(0 ..< 5).delayBy(10.millis)
      iter2 = await mapFilter[int, string](
        iter1,
        proc(i: int): Future[?string] {.async.} =
          if i < 3:
            return some($i)
          else:
            return await fut,
      )

    proc cancelFut(): Future[void] {.async.} =
      await sleepAsync(100.millis)
      await fut.cancelAndWait()

    asyncSpawn(cancelFut())

    var collected: seq[string]

    expect CancelledError:
      for fut in iter2:
        collected.add(await fut)

    check:
      collected == @["0", "1"]
      iter2.finished
