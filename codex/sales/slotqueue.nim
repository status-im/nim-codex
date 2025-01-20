import std/sequtils
import std/tables
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import ../errors
import ../logutils
import ../rng
import ../utils
import ../contracts/requests
import ../utils/asyncheapqueue
import ../utils/trackedfutures

logScope:
  topics = "marketplace slotqueue"

type
  OnProcessSlot* =
    proc(item: SlotQueueItem, done: Future[void]): Future[void] {.gcsafe, upraises:[].}

  # Non-ref obj copies value when assigned, preventing accidental modification
  # of values which could cause an incorrect order (eg
  # ``slotQueue[1].collateral = 1`` would cause ``collateral`` to be updated,
  # but the heap invariant would no longer be honoured. When non-ref, the
  # compiler can ensure that statement will fail).
  SlotQueueWorker = object
    doneProcessing*: Future[void]

  SlotQueueItem* = object
    requestId: RequestId
    slotIndex: uint16
    slotSize: UInt256
    duration: UInt256
    pricePerBytePerSecond: UInt256
    collateralPerByte: UInt256
    expiry: UInt256
    seen: bool

  # don't need to -1 to prevent overflow when adding 1 (to always allow push)
  # because AsyncHeapQueue size is of type `int`, which is larger than `uint16`
  SlotQueueSize = range[1'u16..uint16.high]

  SlotQueue* = ref object
    maxWorkers: int
    onProcessSlot: ?OnProcessSlot
    queue: AsyncHeapQueue[SlotQueueItem]
    running: bool
    workers: AsyncQueue[SlotQueueWorker]
    trackedFutures: TrackedFutures
    unpaused: AsyncEvent

  SlotQueueError = object of CodexError
  SlotQueueItemExistsError* = object of SlotQueueError
  SlotQueueItemNotExistsError* = object of SlotQueueError
  SlotsOutOfRangeError* = object of SlotQueueError
  QueueNotRunningError* = object of SlotQueueError

# Number of concurrent workers used for processing SlotQueueItems
const DefaultMaxWorkers = 3

# Cap slot queue size to prevent unbounded growth and make sifting more
# efficient. Max size is not equivalent to the number of slots a host can
# service, which is limited by host availabilities and new requests circulating
# the network. Additionally, each new request/slot in the network will be
# included in the queue if it is higher priority than any of the exisiting
# items. Older slots should be unfillable over time as other hosts fill the
# slots.
const DefaultMaxSize = 128'u16

proc profitability(item: SlotQueueItem): UInt256 =
  StorageAsk(duration: item.duration,
             pricePerBytePerSecond: item.pricePerBytePerSecond,
             slotSize: item.slotSize).pricePerSlot

proc `<`*(a, b: SlotQueueItem): bool =
  # for A to have a higher priority than B (in a min queue), A must be less than
  # B.
  var scoreA: uint8 = 0
  var scoreB: uint8 = 0

  proc addIf(score: var uint8, condition: bool, addition: int) =
    if condition:
      score += 1'u8 shl addition

  scoreA.addIf(a.seen < b.seen, 4)
  scoreB.addIf(a.seen > b.seen, 4)

  scoreA.addIf(a.profitability > b.profitability, 3)
  scoreB.addIf(a.profitability < b.profitability, 3)

  scoreA.addIf(a.collateralPerByte < b.collateralPerByte, 2)
  scoreB.addIf(a.collateralPerByte > b.collateralPerByte, 2)

  scoreA.addIf(a.expiry > b.expiry, 1)
  scoreB.addIf(a.expiry < b.expiry, 1)

  scoreA.addIf(a.slotSize < b.slotSize, 0)
  scoreB.addIf(a.slotSize > b.slotSize, 0)

  return scoreA > scoreB

proc `==`*(a, b: SlotQueueItem): bool =
  a.requestId == b.requestId and
  a.slotIndex == b.slotIndex

proc new*(_: type SlotQueue,
          maxWorkers = DefaultMaxWorkers,
          maxSize: SlotQueueSize = DefaultMaxSize): SlotQueue =

  if maxWorkers <= 0:
    raise newException(ValueError, "maxWorkers must be positive")
  if maxWorkers.uint16 > maxSize:
    raise newException(ValueError, "maxWorkers must be less than maxSize")

  SlotQueue(
    maxWorkers: maxWorkers,
    # Add 1 to always allow for an extra item to be pushed onto the queue
    # temporarily. After push (and sort), the bottom-most item will be deleted
    queue: newAsyncHeapQueue[SlotQueueItem](maxSize.int + 1),
    running: false,
    trackedFutures: TrackedFutures.new(),
    unpaused: newAsyncEvent()
  )
  # avoid instantiating `workers` in constructor to avoid side effects in
  # `newAsyncQueue` procedure

proc init(_: type SlotQueueWorker): SlotQueueWorker =
  SlotQueueWorker(
    doneProcessing: newFuture[void]("slotqueue.worker.processing")
  )

proc init*(_: type SlotQueueItem,
          requestId: RequestId,
          slotIndex: uint16,
          ask: StorageAsk,
          expiry: UInt256,
          seen = false): SlotQueueItem =

  SlotQueueItem(
    requestId: requestId,
    slotIndex: slotIndex,
    slotSize: ask.slotSize,
    duration: ask.duration,
    pricePerBytePerSecond: ask.pricePerBytePerSecond,
    collateralPerByte: ask.collateralPerByte,
    expiry: expiry,
    seen: seen
  )

proc init*(_: type SlotQueueItem,
           request: StorageRequest,
           slotIndex: uint16): SlotQueueItem =

  SlotQueueItem.init(request.id,
                     slotIndex,
                     request.ask,
                     request.expiry)

proc init*(_: type SlotQueueItem,
          requestId: RequestId,
          ask: StorageAsk,
          expiry: UInt256): seq[SlotQueueItem] =

  if not ask.slots.inRange:
    raise newException(SlotsOutOfRangeError, "Too many slots")

  var i = 0'u16
  proc initSlotQueueItem: SlotQueueItem =
    let item = SlotQueueItem.init(requestId, i, ask, expiry)
    inc i
    return item

  var items = newSeqWith(ask.slots.int, initSlotQueueItem())
  Rng.instance.shuffle(items)
  return items

proc init*(_: type SlotQueueItem,
          request: StorageRequest): seq[SlotQueueItem] =

  return SlotQueueItem.init(request.id, request.ask, request.expiry)

proc inRange*(val: SomeUnsignedInt): bool =
  val.uint16 in SlotQueueSize.low..SlotQueueSize.high

proc requestId*(self: SlotQueueItem): RequestId = self.requestId
proc slotIndex*(self: SlotQueueItem): uint16 = self.slotIndex
proc slotSize*(self: SlotQueueItem): UInt256 = self.slotSize
proc duration*(self: SlotQueueItem): UInt256 = self.duration
proc pricePerBytePerSecond*(self: SlotQueueItem): UInt256 =
  self.pricePerBytePerSecond
proc collateralPerByte*(self: SlotQueueItem): UInt256 = self.collateralPerByte
proc seen*(self: SlotQueueItem): bool = self.seen

proc running*(self: SlotQueue): bool = self.running

proc len*(self: SlotQueue): int = self.queue.len

proc size*(self: SlotQueue): int = self.queue.size - 1

proc paused*(self: SlotQueue): bool = not self.unpaused.isSet

proc `$`*(self: SlotQueue): string = $self.queue

proc `onProcessSlot=`*(self: SlotQueue, onProcessSlot: OnProcessSlot) =
  self.onProcessSlot = some onProcessSlot

proc activeWorkers*(self: SlotQueue): int =
  if not self.running: return 0

  # active = capacity - available
  self.maxWorkers - self.workers.len

proc contains*(self: SlotQueue, item: SlotQueueItem): bool =
  self.queue.contains(item)

proc pause*(self: SlotQueue) =
  # set unpaused flag to false -- coroutines will block on unpaused.wait()
  self.unpaused.clear()

proc unpause*(self: SlotQueue) =
  # set unpaused flag to true -- unblocks coroutines waiting on unpaused.wait()
  self.unpaused.fire()

proc populateItem*(self: SlotQueue,
                   requestId: RequestId,
                   slotIndex: uint16): ?SlotQueueItem =

  trace "populate item, items in queue", len = self.queue.len
  for item in self.queue.items:
    trace "populate item search", itemRequestId = item.requestId, requestId
    if item.requestId == requestId:
      return some SlotQueueItem(
        requestId: requestId,
        slotIndex: slotIndex,
        slotSize: item.slotSize,
        duration: item.duration,
        pricePerBytePerSecond: item.pricePerBytePerSecond,
        collateralPerByte: item.collateralPerByte,
        expiry: item.expiry
      )
  return none SlotQueueItem

proc push*(self: SlotQueue, item: SlotQueueItem): ?!void =

  logScope:
    requestId = item.requestId
    slotIndex = item.slotIndex
    seen = item.seen

  trace "pushing item to queue"

  if not self.running:
    let err = newException(QueueNotRunningError, "queue not running")
    return failure(err)

  if self.contains(item):
    let err = newException(SlotQueueItemExistsError, "item already exists")
    return failure(err)

  if err =? self.queue.pushNoWait(item).mapFailure.errorOption:
    return failure(err)

  if self.queue.full():
    # delete the last item
    self.queue.del(self.queue.size - 1)

  doAssert self.queue.len <= self.queue.size - 1

  # when slots are pushed to the queue, the queue should be unpaused if it was
  # paused
  if self.paused and not item.seen:
    trace "unpausing queue after new slot pushed"
    self.unpause()

  return success()

proc push*(self: SlotQueue, items: seq[SlotQueueItem]): ?!void =
  for item in items:
    if err =? self.push(item).errorOption:
      return failure(err)

  return success()

proc findByRequest(self: SlotQueue, requestId: RequestId): seq[SlotQueueItem] =
  var items: seq[SlotQueueItem] = @[]
  for item in self.queue.items:
    if item.requestId == requestId:
      items.add item
  return items

proc delete*(self: SlotQueue, item: SlotQueueItem) =
  logScope:
    requestId = item.requestId
    slotIndex = item.slotIndex

  trace "removing item from queue"

  if not self.running:
    trace "cannot delete item from queue, queue not running"
    return

  self.queue.delete(item)

proc delete*(self: SlotQueue, requestId: RequestId, slotIndex: uint16) =
  let item = SlotQueueItem(requestId: requestId, slotIndex: slotIndex)
  self.delete(item)

proc delete*(self: SlotQueue, requestId: RequestId) =
  let items = self.findByRequest(requestId)
  for item in items:
    self.delete(item)

proc `[]`*(self: SlotQueue, i: Natural): SlotQueueItem =
  self.queue[i]

proc addWorker(self: SlotQueue): ?!void =
  if not self.running:
    let err = newException(QueueNotRunningError, "queue must be running")
    return failure(err)

  trace "adding new worker to worker queue"

  let worker = SlotQueueWorker.init()
  try:
    self.trackedFutures.track(worker.doneProcessing)
    self.workers.addLastNoWait(worker)
  except AsyncQueueFullError:
    return failure("failed to add worker, worker queue full")

  return success()

proc dispatch(self: SlotQueue,
              worker: SlotQueueWorker,
              item: SlotQueueItem) {.async: (raises: []).} =
  logScope:
    requestId = item.requestId
    slotIndex = item.slotIndex

  if not self.running:
    warn "Could not dispatch worker because queue is not running"
    return

  if onProcessSlot =? self.onProcessSlot:
    try:
      self.trackedFutures.track(worker.doneProcessing)
      await onProcessSlot(item, worker.doneProcessing)
      await worker.doneProcessing

      if err =? self.addWorker().errorOption:
        raise err # catch below

    except QueueNotRunningError as e:
      info "could not re-add worker to worker queue, queue not running",
        error = e.msg
    except CancelledError:
      # do not bubble exception up as it is called with `asyncSpawn` which would
      # convert the exception into a `FutureDefect`
      discard
    except CatchableError as e:
      # we don't have any insight into types of errors that `onProcessSlot` can
      # throw because it is caller-defined
      warn "Unknown error processing slot in worker", error = e.msg

proc clearSeenFlags*(self: SlotQueue) =
  # Enumerate all items in the queue, overwriting each item with `seen = false`.
  # To avoid issues with new queue items being pushed to the queue while all
  # items are being iterated (eg if a new storage request comes in and pushes
  # new slots to the queue), this routine must remain synchronous.

  if self.queue.empty:
    return

  for item in self.queue.mitems:
    item.seen = false # does not maintain the heap invariant

  # force heap reshuffling to maintain the heap invariant
  doAssert self.queue.update(self.queue[0]), "slot queue failed to reshuffle"

  trace "all 'seen' flags cleared"

proc run(self: SlotQueue) {.async: (raises: []).} =

  while self.running:
    try:
      if self.paused:
        trace "Queue is paused, waiting for new slots or availabilities to be modified/added"

      # block until unpaused is true/fired, ie wait for queue to be unpaused
      await self.unpaused.wait()

      let worker = await self.workers.popFirst() # if workers saturated, wait here for new workers
      let item = await self.queue.pop() # if queue empty, wait here for new items

      logScope:
        reqId = item.requestId
        slotIdx = item.slotIndex
        seen = item.seen

      if not self.running: # may have changed after waiting for pop
        trace "not running, exiting"
        break

      # If, upon processing a slot, the slot item already has a `seen` flag set,
      # the queue should be paused.
      if item.seen:
        trace "processing already seen item, pausing queue",
          reqId = item.requestId, slotIdx = item.slotIndex
        self.pause()
        # put item back in queue so that if other items are pushed while paused,
        # it will be sorted accordingly. Otherwise, this item would be processed
        # immediately (with priority over other items) once unpaused
        trace "readding seen item back into the queue"
        discard self.push(item) # on error, drop the item and continue
        worker.doneProcessing.complete()
        await sleepAsync(1.millis) # poll
        continue

      trace "processing item"

      let fut = self.dispatch(worker, item)
      self.trackedFutures.track(fut)
      asyncSpawn fut

      await sleepAsync(1.millis) # poll
    except CancelledError:
      trace "slot queue cancelled"
      break
    except CatchableError as e: # raised from self.queue.pop() or self.workers.pop()
      warn "slot queue error encountered during processing", error = e.msg

proc start*(self: SlotQueue) =
  if self.running:
    return

  trace "starting slot queue"

  self.running = true

  # must be called in `start` to avoid sideeffects in `new`
  self.workers = newAsyncQueue[SlotQueueWorker](self.maxWorkers)

  # Add initial workers to the `AsyncHeapQueue`. Once a worker has completed its
  # task, a new worker will be pushed to the queue
  for i in 0..<self.maxWorkers:
    if err =? self.addWorker().errorOption:
      error "start: error adding new worker", error = err.msg

  let fut = self.run()
  self.trackedFutures.track(fut)
  asyncSpawn fut

proc stop*(self: SlotQueue) {.async.} =
  if not self.running:
    return

  trace "stopping slot queue"

  self.running = false

  await self.trackedFutures.cancelTracked()
