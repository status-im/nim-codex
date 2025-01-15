import pkg/chronos
import pkg/stew/results

import pkg/codex/utils/asyncheapqueue
import pkg/codex/rng

import ../asynctest
import ./helpers

type Task* = tuple[name: string, priority: int]

proc `<`*(a, b: Task): bool =
  a.priority < b.priority

proc `==`*(a, b: Task): bool =
  a.name == b.name

proc toSortedSeq[T](h: AsyncHeapQueue[T], queueType = QueueType.Min): seq[T] =
  var tmp = newAsyncHeapQueue[T](queueType = queueType)
  for d in h:
    check tmp.pushNoWait(d).isOk
  while tmp.len > 0:
    result.add(popNoWait(tmp).tryGet())

checksuite "Synchronous tests":
  test "Test pushNoWait - Min":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      check heap.pushNoWait(item).isOk

    check heap[0] == 0
    check heap.toSortedSeq == @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

  test "Test pushNoWait - Max":
    var heap = newAsyncHeapQueue[int](queueType = QueueType.Max)
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      check heap.pushNoWait(item).isOk

    check heap[0] == 9
    check heap.toSortedSeq(QueueType.Max) == @[9, 8, 7, 6, 5, 4, 3, 2, 1, 0]

  test "Test popNoWait":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      check heap.pushNoWait(item).isOk

    var res: seq[int]
    while heap.len > 0:
      let r = heap.popNoWait()
      if r.isOk:
        res.add(r.get)

    check res == @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

  test "Test popNoWait - Max":
    var heap = newAsyncHeapQueue[int](queueType = QueueType.Max)
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      check heap.pushNoWait(item).isOk

    var res: seq[int]
    while heap.len > 0:
      let r = heap.popNoWait()
      if r.isOk:
        res.add(r.get)

    check res == @[9, 8, 7, 6, 5, 4, 3, 2, 1, 0]

  test "Test del":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      check heap.pushNoWait(item).isOk

    heap.del(0)
    doAssert(heap[0] == 1)

    heap.del(heap.find(7))
    check heap.toSortedSeq == @[1, 2, 3, 4, 5, 6, 8, 9]

    heap.del(heap.find(5))
    check heap.toSortedSeq == @[1, 2, 3, 4, 6, 8, 9]

    heap.del(heap.find(6))
    check heap.toSortedSeq == @[1, 2, 3, 4, 8, 9]

    heap.del(heap.find(2))
    check heap.toSortedSeq == @[1, 3, 4, 8, 9]

  test "Test del last":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 2, 3]
    for item in data:
      check heap.pushNoWait(item).isOk

    heap.del(2)
    check heap.toSortedSeq == @[1, 2]

    heap.del(1)
    check heap.toSortedSeq == @[1]

    heap.del(0)
    check heap.toSortedSeq == newSeq[int]() # empty seq has no type

  test "Should throw popping from an empty queue":
    var heap = newAsyncHeapQueue[int]()
    let err = heap.popNoWait()
    check err.isErr
    check err.error == AsyncHQErrors.Empty

  test "Should throw pushing to an full queue":
    var heap = newAsyncHeapQueue[int](1)
    check heap.pushNoWait(1).isOk
    let err = heap.pushNoWait(2)
    check err.isErr
    check err.error == AsyncHQErrors.Full

  test "Test clear":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      check heap.pushNoWait(item).isOk

    check heap.len == 10
    heap.clear()
    check heap.len == 0

asyncchecksuite "Asynchronous Tests":
  test "Test push":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      await push(heap, item)
    check heap[0] == 0
    check heap.toSortedSeq == @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

  test "Test push and pop with maxSize":
    var heap = newAsyncHeapQueue[int](5)
    let data = [1, 9, 5, 3, 7, 4, 2]

    proc pushTask() {.async.} =
      for item in data:
        await push(heap, item)

    asyncSpawn pushTask()

    check heap.len == 5
    check heap[0] == 1 # because we haven't pushed 0 yet

    check (await heap.pop) == 1
    check (await heap.pop) == 3
    check (await heap.pop) == 5
    check (await heap.pop) == 7
    check (await heap.pop) == 9

    await sleepAsync(1.milliseconds) # allow poll to run once more
    check (await heap.pop) == 2
    check (await heap.pop) == 4

  test "Test update":
    var heap = newAsyncHeapQueue[Task](5)
    let data = [("a", 4), ("b", 3), ("c", 2)]

    for item in data:
      check heap.pushNoWait(item).isOk

    check heap[0] == (name: "c", priority: 2)
    check heap.update((name: "a", priority: 1))
    check heap[0] == (name: "a", priority: 1)

  test "Test pushOrUpdate - update":
    var heap = newAsyncHeapQueue[Task](3)
    let data = [("a", 4), ("b", 3), ("c", 2)]

    for item in data:
      check heap.pushNoWait(item).isOk

    check heap[0] == (name: "c", priority: 2)
    await heap.pushOrUpdate((name: "a", priority: 1))
    check heap[0] == (name: "a", priority: 1)

  test "Test pushOrUpdate - push":
    var heap = newAsyncHeapQueue[Task](2)
    let data = [("a", 4), ("b", 3)]

    for item in data:
      check heap.pushNoWait(item).isOk

    check heap[0] == ("b", 3) # sanity check for order

    let fut = heap.pushOrUpdate(("c", 2)) # attempt to push a non existen item but block
    check heap.popNoWait().tryGet() == ("b", 3) # pop one off
    await fut # wait for push to complete

    check heap[0] == (name: "c", priority: 2) # check order again

  test "Test pop":
    var heap = newAsyncHeapQueue[int]()
    let data = [1, 3, 5, 7, 9, 2, 4, 6, 8, 0]
    for item in data:
      check heap.pushNoWait(item).isOk

    var res: seq[int]
    while heap.len > 0:
      res.add((await heap.pop()))

    check res == @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

  test "Test delete":
    var heap = newAsyncHeapQueue[Task]()
    let data = ["d", "b", "c", "a", "h", "e", "f", "g"]

    for item in data:
      check heap.pushNoWait((name: item, priority: Rng.instance().rand(data.len))).isOk

    let del = heap[3]
    heap.delete(del)
    check heap.find(del) < 0
