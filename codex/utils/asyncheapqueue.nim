## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import pkg/chronos
import pkg/stew/results

# Based on chronos AsyncHeapQueue and std/heapqueue

type
  QueueType* {.pure.} = enum
    Min
    Max

  AsyncHeapQueue*[T] = ref object of RootRef
    ## A priority queue
    ##
    ## If ``maxsize`` is less than or equal to zero, the queue size is
    ## infinite. If it is an integer greater than ``0``, then "await put()"
    ## will block when the queue reaches ``maxsize``, until an item is
    ## removed by "await get()".
    queueType: QueueType
    getters: seq[Future[void]]
    putters: seq[Future[void]]
    queue: seq[T]
    maxsize: int

  AsyncHQErrors* {.pure.} = enum
    Empty
    Full

proc newAsyncHeapQueue*[T](
    maxsize: int = 0, queueType: QueueType = QueueType.Min
): AsyncHeapQueue[T] =
  ## Creates a new asynchronous queue ``AsyncHeapQueue``.
  ##

  AsyncHeapQueue[T](
    getters: newSeq[Future[void]](),
    putters: newSeq[Future[void]](),
    queue: newSeqOfCap[T](maxsize),
    maxsize: maxsize,
    queueType: queueType,
  )

proc wakeupNext(waiters: var seq[Future[void]]) {.inline.} =
  var i = 0
  while i < len(waiters):
    var waiter = waiters[i]
    inc(i)

    if not (waiter.finished()):
      waiter.complete()
      break

  if i > 0:
    waiters.delete(0 .. (i - 1))

proc heapCmp[T](x, y: T, max: bool = false): bool {.inline.} =
  if max:
    return (y < x)
  else:
    return (x < y)

proc siftdown[T](heap: AsyncHeapQueue[T], startpos, p: int) =
  ## 'heap' is a heap at all indices >= startpos, except
  ## possibly for pos.  pos is the index of a leaf with a
  ## possibly out-of-order value. Restore the heap invariant.
  ##

  var pos = p
  var newitem = heap[pos]
  # Follow the path to the root, moving parents down until
  # finding a place newitem fits.
  while pos > startpos:
    let parentpos = (pos - 1) shr 1
    let parent = heap[parentpos]
    if heapCmp(newitem, parent, heap.queueType == QueueType.Max):
      heap.queue[pos] = parent
      pos = parentpos
    else:
      break
  heap.queue[pos] = newitem

proc siftup[T](heap: AsyncHeapQueue[T], p: int) =
  let endpos = len(heap)
  var pos = p
  let startpos = pos
  let newitem = heap[pos]
  # Bubble up the smaller child until hitting a leaf.
  var childpos = 2 * pos + 1 # leftmost child position
  while childpos < endpos:
    # Set childpos to index of smaller child.
    let rightpos = childpos + 1
    if rightpos < endpos and
        not heapCmp(heap[childpos], heap[rightpos], heap.queueType == QueueType.Max):
      childpos = rightpos
    # Move the smaller child up.
    heap.queue[pos] = heap[childpos]
    pos = childpos
    childpos = 2 * pos + 1
  # The leaf at pos is empty now.  Put newitem there, and bubble it up
  # to its final resting place (by sifting its parents down).
  heap.queue[pos] = newitem
  siftdown(heap, startpos, pos)

proc full*[T](heap: AsyncHeapQueue[T]): bool {.inline.} =
  ## Return ``true`` if there are ``maxsize`` items in the queue.
  ##
  ## Note: If the ``heap`` was initialized with ``maxsize = 0`` (default),
  ## then ``full()`` is never ``true``.
  if heap.maxsize <= 0:
    false
  else:
    (len(heap.queue) >= heap.maxsize)

proc empty*[T](heap: AsyncHeapQueue[T]): bool {.inline.} =
  ## Return ``true`` if the queue is empty, ``false`` otherwise.
  (len(heap.queue) == 0)

proc pushNoWait*[T](heap: AsyncHeapQueue[T], item: T): Result[void, AsyncHQErrors] =
  ## Push `item` onto heap, maintaining the heap invariant.
  ##

  if heap.full():
    return err(AsyncHQErrors.Full)

  heap.queue.add(item)
  siftdown(heap, 0, len(heap) - 1)
  heap.getters.wakeupNext()

  return ok()

proc push*[T](heap: AsyncHeapQueue[T], item: T) {.async, gcsafe.} =
  ## Push item into the queue, awaiting for an available slot
  ## when it's full
  ##

  while heap.full():
    var putter = newFuture[void]("AsyncHeapQueue.push")
    heap.putters.add(putter)
    try:
      await putter
    except CatchableError as exc:
      if not (heap.full()) and not (putter.cancelled()):
        heap.putters.wakeupNext()
      raise exc

  heap.pushNoWait(item).tryGet()

proc popNoWait*[T](heap: AsyncHeapQueue[T]): Result[T, AsyncHQErrors] =
  ## Pop and return the smallest item from `heap`,
  ## maintaining the heap invariant.
  ##

  if heap.empty():
    return err(AsyncHQErrors.Empty)

  let lastelt = heap.queue.pop()
  if heap.len > 0:
    result = ok(heap[0])
    heap.queue[0] = lastelt
    siftup(heap, 0)
  else:
    result = ok(lastelt)

  heap.putters.wakeupNext()

proc pop*[T](heap: AsyncHeapQueue[T]): Future[T] {.async.} =
  ## Remove and return an ``item`` from the beginning of the queue ``heap``.
  ## If the queue is empty, wait until an item is available.
  while heap.empty():
    var getter = newFuture[void]("AsyncHeapQueue.pop")
    heap.getters.add(getter)
    try:
      await getter
    except CatchableError as exc:
      if not (heap.empty()) and not (getter.cancelled()):
        heap.getters.wakeupNext()
      raise exc

  return heap.popNoWait().tryGet()

proc del*[T](heap: AsyncHeapQueue[T], index: Natural) =
  ## Removes the element at `index` from `heap`,
  ## maintaining the heap invariant.
  ##

  if heap.empty():
    return

  swap(heap.queue[^1], heap.queue[index])
  let newLen = heap.len - 1
  heap.queue.setLen(newLen)
  if index < newLen:
    heap.siftup(index)

  heap.putters.wakeupNext()

proc delete*[T](heap: AsyncHeapQueue[T], item: T) =
  ## Find and delete an `item` from the `heap`
  ##

  let index = heap.find(item)
  if index > -1:
    heap.del(index)

proc update*[T](heap: AsyncHeapQueue[T], item: T): bool =
  ## Update an entry in the heap by reshufling its
  ## possition, maintaining the heap invariant.
  ##

  let index = heap.find(item)
  if index > -1:
    # replace item with new one in case it's a copy
    heap.queue[index] = item
    # re-establish heap order
    # TODO: don't start at 0 to avoid reshuffling
    # entire heap
    heap.siftup(0)
    return true

proc pushOrUpdateNoWait*[T](
    heap: AsyncHeapQueue[T], item: T
): Result[void, AsyncHQErrors] =
  ## Update an item if it exists or push a new one
  ##

  if heap.update(item):
    return ok()

  return heap.pushNoWait(item)

proc pushOrUpdate*[T](heap: AsyncHeapQueue[T], item: T) {.async.} =
  ## Update an item if it exists or push a new one
  ## awaiting until a slot becomes available
  ##

  if not heap.update(item):
    await heap.push(item)

proc replace*[T](heap: AsyncHeapQueue[T], item: T): Result[T, AsyncHQErrors] =
  ## Pop and return the current smallest value, and add the new item.
  ## This is more efficient than pop() followed by push(), and can be
  ## more appropriate when using a fixed-size heap. Note that the value
  ## returned may be larger than item! That constrains reasonable uses of
  ## this routine unless written as part of a conditional replacement:
  ##
  ## .. code-block:: nim
  ##    if item > heap[0]:
  ##        item = replace(heap, item)
  ##

  if heap.empty():
    error(AsyncHQErrors.Empty)

  result = heap[0]
  heap.queue[0] = item
  siftup(heap, 0)

proc pushPopNoWait*[T](heap: AsyncHeapQueue[T], item: T): Result[T, AsyncHQErrors] =
  ## Fast version of a push followed by a pop.
  ##

  if heap.empty():
    err(AsyncHQErrors.Empty)

  if heap.len > 0 and heapCmp(heap[0], item, heap.queueType == QueueType.Max):
    swap(item, heap[0])
    siftup(heap, 0)
  return item

proc clear*[T](heap: AsyncHeapQueue[T]) {.inline.} =
  ## Clears all elements of queue ``heap``.
  heap.queue.setLen(0)

proc len*[T](heap: AsyncHeapQueue[T]): int {.inline.} =
  ## Return the number of elements in ``heap``.
  len(heap.queue)

proc size*[T](heap: AsyncHeapQueue[T]): int {.inline.} =
  ## Return the maximum number of elements in ``heap``.
  heap.maxsize

proc `[]`*[T](heap: AsyncHeapQueue[T], i: Natural): T {.inline.} =
  ## Access the i-th element of ``heap`` by order from first to last.
  ## ``heap[0]`` is the first element, ``heap[^1]`` is the last element.
  heap.queue[i]

proc `[]`*[T](heap: AsyncHeapQueue[T], i: BackwardsIndex): T {.inline.} =
  ## Access the i-th element of ``heap`` by order from first to last.
  ## ``heap[0]`` is the first element, ``heap[^1]`` is the last element.
  heap.queue[len(heap.queue) - int(i)]

iterator items*[T](heap: AsyncHeapQueue[T]): T {.inline.} =
  ## Yield every element of ``heap``.
  for item in heap.queue.items():
    yield item

iterator mitems*[T](heap: AsyncHeapQueue[T]): var T {.inline.} =
  ## Yield every element of ``heap``.
  for mitem in heap.queue.mitems():
    yield mitem

iterator pairs*[T](heap: AsyncHeapQueue[T]): tuple[key: int, val: T] {.inline.} =
  ## Yield every (position, value) of ``heap``.
  for pair in heap.queue.pairs():
    yield pair

proc contains*[T](heap: AsyncHeapQueue[T], item: T): bool {.inline.} =
  ## Return true if ``item`` is in ``heap`` or false if not found. Usually used
  ## via the ``in`` operator.
  for e in heap.queue.items():
    if e == item:
      return true
  return false

proc `$`*[T](heap: AsyncHeapQueue[T]): string =
  ## Turn an async queue ``heap`` into its string representation.
  var res = "["
  for item in heap.queue.items():
    if len(res) > 1:
      res.add(", ")
    res.addQuoted(item)
  res.add("]")
  res
