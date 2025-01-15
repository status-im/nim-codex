import std/sequtils
import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import pkg/codex/logutils
import pkg/codex/sales/slotqueue

import ../../asynctest
import ../helpers
import ../helpers/mockmarket
import ../helpers/mockslotqueueitem
import ../examples

suite "Slot queue start/stop":
  var queue: SlotQueue

  setup:
    queue = SlotQueue.new()

  teardown:
    await queue.stop()

  test "starts out not running":
    check not queue.running

  test "can call start multiple times, and when already running":
    queue.start()
    queue.start()
    check queue.running

  test "can call stop when alrady stopped":
    await queue.stop()
    check not queue.running

  test "can call stop when running":
    queue.start()
    await queue.stop()
    check not queue.running

  test "can call stop multiple times":
    queue.start()
    await queue.stop()
    await queue.stop()
    check not queue.running

suite "Slot queue workers":
  var queue: SlotQueue

  proc onProcessSlot(item: SlotQueueItem, doneProcessing: Future[void]) {.async.} =
    await sleepAsync(1000.millis)
    # this is not illustrative of the realistic scenario as the
    # `doneProcessing` future would be passed to another context before being
    # completed and therefore is not as simple as making the callback async
    doneProcessing.complete()

  setup:
    let request = StorageRequest.example
    queue = SlotQueue.new(maxSize = 5, maxWorkers = 3)
    queue.onProcessSlot = onProcessSlot

  teardown:
    await queue.stop()

  test "activeWorkers should be 0 when not running":
    check queue.activeWorkers == 0

  test "maxWorkers cannot be 0":
    expect ValueError:
      discard SlotQueue.new(maxSize = 1, maxWorkers = 0)

  test "maxWorkers cannot surpass maxSize":
    expect ValueError:
      discard SlotQueue.new(maxSize = 1, maxWorkers = 2)

  test "does not surpass max workers":
    queue.start()
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    let item3 = SlotQueueItem.example
    let item4 = SlotQueueItem.example
    check queue.push(item1).isOk
    check queue.push(item2).isOk
    check queue.push(item3).isOk
    check queue.push(item4).isOk
    check eventually queue.activeWorkers == 3

  test "discards workers once processing completed":
    proc processSlot(item: SlotQueueItem, done: Future[void]) {.async.} =
      await sleepAsync(1.millis)
      done.complete()

    queue.onProcessSlot = processSlot

    queue.start()
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    let item3 = SlotQueueItem.example
    let item4 = SlotQueueItem.example
    check queue.push(item1).isOk # finishes after 1.millis
    check queue.push(item2).isOk # finishes after 1.millis
    check queue.push(item3).isOk # finishes after 1.millis
    check queue.push(item4).isOk
    check eventually queue.activeWorkers == 1

suite "Slot queue":
  var onProcessSlotCalled = false
  var onProcessSlotCalledWith: seq[(RequestId, uint16)]
  var queue: SlotQueue
  var paused: bool

  proc newSlotQueue(maxSize, maxWorkers: int, processSlotDelay = 1.millis) =
    queue = SlotQueue.new(maxWorkers, maxSize.uint16)
    queue.onProcessSlot = proc(item: SlotQueueItem, done: Future[void]) {.async.} =
      await sleepAsync(processSlotDelay)
      onProcessSlotCalled = true
      onProcessSlotCalledWith.add (item.requestId, item.slotIndex)
      done.complete()
    queue.start()

  setup:
    onProcessSlotCalled = false
    onProcessSlotCalledWith = @[]

  teardown:
    paused = false

    await queue.stop()

  test "starts out empty":
    newSlotQueue(maxSize = 2, maxWorkers = 2)
    check queue.len == 0
    check $queue == "[]"

  test "reports correct size":
    newSlotQueue(maxSize = 2, maxWorkers = 2)
    check queue.size == 2

  test "correctly compares SlotQueueItems":
    var requestA = StorageRequest.example
    requestA.ask.duration = 1.u256
    requestA.ask.reward = 1.u256
    check requestA.ask.pricePerSlot == 1.u256
    requestA.ask.collateral = 100000.u256
    requestA.expiry = 1001.u256

    var requestB = StorageRequest.example
    requestB.ask.duration = 100.u256
    requestB.ask.reward = 1000.u256
    check requestB.ask.pricePerSlot == 100000.u256
    requestB.ask.collateral = 1.u256
    requestB.expiry = 1000.u256

    let itemA = SlotQueueItem.init(requestA, 0)
    let itemB = SlotQueueItem.init(requestB, 0)
    check itemB < itemA # B higher priority than A
    check itemA > itemB

  test "correct prioritizes SlotQueueItems based on 'seen'":
    let request = StorageRequest.example
    let itemA = MockSlotQueueItem(
      requestId: request.id,
      slotIndex: 0,
      slotSize: 1.u256,
      duration: 1.u256,
      reward: 2.u256, # profitability is higher (good)
      collateral: 1.u256,
      expiry: 1.u256,
      seen: true, # seen (bad), more weight than profitability
    )
    let itemB = MockSlotQueueItem(
      requestId: request.id,
      slotIndex: 0,
      slotSize: 1.u256,
      duration: 1.u256,
      reward: 1.u256, # profitability is lower (bad)
      collateral: 1.u256,
      expiry: 1.u256,
      seen: false, # not seen (good)
    )
    check itemB.toSlotQueueItem < itemA.toSlotQueueItem # B higher priority than A
    check itemA.toSlotQueueItem > itemB.toSlotQueueItem

  test "correct prioritizes SlotQueueItems based on profitability":
    let request = StorageRequest.example
    let itemA = MockSlotQueueItem(
      requestId: request.id,
      slotIndex: 0,
      slotSize: 1.u256,
      duration: 1.u256,
      reward: 1.u256, # reward is lower (bad)
      collateral: 1.u256, # collateral is lower (good)
      expiry: 1.u256,
      seen: false,
    )
    let itemB = MockSlotQueueItem(
      requestId: request.id,
      slotIndex: 0,
      slotSize: 1.u256,
      duration: 1.u256,
      reward: 2.u256, # reward is higher (good), more weight than collateral
      collateral: 2.u256, # collateral is higher (bad)
      expiry: 1.u256,
      seen: false,
    )

    check itemB.toSlotQueueItem < itemA.toSlotQueueItem # < indicates higher priority

  test "correct prioritizes SlotQueueItems based on collateral":
    let request = StorageRequest.example
    let itemA = MockSlotQueueItem(
      requestId: request.id,
      slotIndex: 0,
      slotSize: 1.u256,
      duration: 1.u256,
      reward: 1.u256,
      collateral: 2.u256, # collateral is higher (bad)
      expiry: 2.u256, # expiry is longer (good)
      seen: false,
    )
    let itemB = MockSlotQueueItem(
      requestId: request.id,
      slotIndex: 0,
      slotSize: 1.u256,
      duration: 1.u256,
      reward: 1.u256,
      collateral: 1.u256, # collateral is lower (good), more weight than expiry
      expiry: 1.u256, # expiry is shorter (bad)
      seen: false,
    )

    check itemB.toSlotQueueItem < itemA.toSlotQueueItem # < indicates higher priority

  test "correct prioritizes SlotQueueItems based on expiry":
    let request = StorageRequest.example
    let itemA = MockSlotQueueItem(
      requestId: request.id,
      slotIndex: 0,
      slotSize: 1.u256, # slotSize is smaller (good)
      duration: 1.u256,
      reward: 1.u256,
      collateral: 1.u256,
      expiry: 1.u256, # expiry is shorter (bad)
      seen: false,
    )
    let itemB = MockSlotQueueItem(
      requestId: request.id,
      slotIndex: 0,
      slotSize: 2.u256, # slotSize is larger (bad)
      duration: 1.u256,
      reward: 1.u256,
      collateral: 1.u256,
      expiry: 2.u256, # expiry is longer (good), more weight than slotSize
      seen: false,
    )

    check itemB.toSlotQueueItem < itemA.toSlotQueueItem # < indicates higher priority

  test "correct prioritizes SlotQueueItems based on slotSize":
    let request = StorageRequest.example
    let itemA = MockSlotQueueItem(
      requestId: request.id,
      slotIndex: 0,
      slotSize: 2.u256, # slotSize is larger (bad)
      duration: 1.u256,
      reward: 1.u256,
      collateral: 1.u256,
      expiry: 1.u256, # expiry is shorter (bad)
      seen: false,
    )
    let itemB = MockSlotQueueItem(
      requestId: request.id,
      slotIndex: 0,
      slotSize: 1.u256, # slotSize is smaller (good)
      duration: 1.u256,
      reward: 1.u256,
      collateral: 1.u256,
      expiry: 1.u256,
      seen: false,
    )

    check itemB.toSlotQueueItem < itemA.toSlotQueueItem # < indicates higher priority

  test "expands available all possible slot indices on init":
    let request = StorageRequest.example
    let items = SlotQueueItem.init(request)
    check items.len.uint64 == request.ask.slots
    var checked = 0
    for slotIndex in 0'u16 ..< request.ask.slots.uint16:
      check items.anyIt(it == SlotQueueItem.init(request, slotIndex))
      inc checked
    check checked == items.len

  test "can process items":
    newSlotQueue(maxSize = 2, maxWorkers = 2)
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    check queue.push(item1).isOk
    check queue.push(item2).isOk
    check eventually onProcessSlotCalledWith ==
      @[(item1.requestId, item1.slotIndex), (item2.requestId, item2.slotIndex)]

  test "can push items past number of maxWorkers":
    newSlotQueue(maxSize = 2, maxWorkers = 2)
    let item0 = SlotQueueItem.example
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    let item3 = SlotQueueItem.example
    let item4 = SlotQueueItem.example
    check isOk queue.push(item0)
    check isOk queue.push(item1)
    check isOk queue.push(item2)
    check isOk queue.push(item3)
    check isOk queue.push(item4)

  test "populates item with exisiting request metadata":
    newSlotQueue(maxSize = 8, maxWorkers = 1, processSlotDelay = 10.millis)
    let request0 = StorageRequest.example
    var request1 = StorageRequest.example
    request1.ask.collateral += 1.u256
    let items0 = SlotQueueItem.init(request0)
    let items1 = SlotQueueItem.init(request1)
    check queue.push(items0).isOk
    check queue.push(items1).isOk
    let populated = !queue.populateItem(request1.id, 12'u16)
    check populated.requestId == request1.id
    check populated.slotIndex == 12'u16
    check populated.slotSize == request1.ask.slotSize
    check populated.duration == request1.ask.duration
    check populated.reward == request1.ask.reward
    check populated.collateral == request1.ask.collateral

  test "does not find exisiting request metadata":
    newSlotQueue(maxSize = 2, maxWorkers = 2)
    let item = SlotQueueItem.example
    check queue.populateItem(item.requestId, 12'u16).isNone

  test "can support uint16.high slots":
    var request = StorageRequest.example
    let maxUInt16 = uint16.high
    let uint64Slots = uint64(maxUInt16)
    request.ask.slots = uint64Slots
    let items = SlotQueueItem.init(request.id, request.ask, request.expiry)
    check items.len.uint16 == maxUInt16

  test "cannot support greater than uint16.high slots":
    var request = StorageRequest.example
    let int32Slots = uint16.high.int32 + 1
    let uint64Slots = uint64(int32Slots)
    request.ask.slots = uint64Slots
    expect SlotsOutOfRangeError:
      discard SlotQueueItem.init(request.id, request.ask, request.expiry)

  test "cannot push duplicate items":
    newSlotQueue(maxSize = 6, maxWorkers = 1, processSlotDelay = 15.millis)
    let item0 = SlotQueueItem.example
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    check isOk queue.push(item0)
    check isOk queue.push(item1)
    check queue.push(@[item2, item2, item2, item2]).error of SlotQueueItemExistsError

  test "can add items past max maxSize":
    newSlotQueue(maxSize = 4, maxWorkers = 2, processSlotDelay = 10.millis)
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    let item3 = SlotQueueItem.example
    let item4 = SlotQueueItem.example
    check queue.push(item1).isOk
    check queue.push(item2).isOk
    check queue.push(item3).isOk
    check queue.push(item4).isOk
    check eventually onProcessSlotCalledWith.len == 4

  test "can delete items":
    newSlotQueue(maxSize = 6, maxWorkers = 2, processSlotDelay = 10.millis)
    let item0 = SlotQueueItem.example
    let item1 = SlotQueueItem.example
    let item2 = SlotQueueItem.example
    let item3 = SlotQueueItem.example
    check queue.push(item0).isOk
    check queue.push(item1).isOk
    check queue.push(item2).isOk
    check queue.push(item3).isOk
    queue.delete(item3)
    check not queue.contains(item3)

  test "can delete item by request id and slot id":
    newSlotQueue(maxSize = 8, maxWorkers = 1, processSlotDelay = 10.millis)
    let request0 = StorageRequest.example
    var request1 = StorageRequest.example
    request1.ask.collateral += 1.u256
    let items0 = SlotQueueItem.init(request0)
    let items1 = SlotQueueItem.init(request1)
    check queue.push(items0).isOk
    check queue.push(items1).isOk
    let last = items1[items1.high]
    check eventually queue.contains(last)
    queue.delete(last.requestId, last.slotIndex)
    check not onProcessSlotCalledWith.anyIt(it == (last.requestId, last.slotIndex))

  test "can delete all items by request id":
    newSlotQueue(maxSize = 8, maxWorkers = 1, processSlotDelay = 10.millis)
    let request0 = StorageRequest.example
    var request1 = StorageRequest.example
    request1.ask.collateral += 1.u256
    let items0 = SlotQueueItem.init(request0)
    let items1 = SlotQueueItem.init(request1)
    check queue.push(items0).isOk
    check queue.push(items1).isOk
    queue.delete(request1.id)
    check not onProcessSlotCalledWith.anyIt(it[0] == request1.id)

  test "can check if contains item":
    newSlotQueue(maxSize = 6, maxWorkers = 1, processSlotDelay = 10.millis)
    let request0 = StorageRequest.example
    var request1 = StorageRequest.example
    var request2 = StorageRequest.example
    var request3 = StorageRequest.example
    var request4 = StorageRequest.example
    var request5 = StorageRequest.example
    request1.ask.collateral = request0.ask.collateral + 1
    request2.ask.collateral = request1.ask.collateral + 1
    request3.ask.collateral = request2.ask.collateral + 1
    request4.ask.collateral = request3.ask.collateral + 1
    request5.ask.collateral = request4.ask.collateral + 1
    let item0 = SlotQueueItem.init(request0, 0)
    let item1 = SlotQueueItem.init(request1, 0)
    let item2 = SlotQueueItem.init(request2, 0)
    let item3 = SlotQueueItem.init(request3, 0)
    let item4 = SlotQueueItem.init(request4, 0)
    let item5 = SlotQueueItem.init(request5, 0)
    check queue.contains(item5) == false
    check queue.push(@[item0, item1, item2, item3, item4, item5]).isOk
    check queue.contains(item5)

  test "sorts items by profitability ascending (higher pricePerSlot = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0)
    request.ask.reward += 1.u256
    let item1 = SlotQueueItem.init(request, 1)
    check item1 < item0

  test "sorts items by collateral ascending (less required collateral = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0)
    request.ask.collateral -= 1.u256
    let item1 = SlotQueueItem.init(request, 1)
    check item1 < item0

  test "sorts items by expiry descending (longer expiry = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0)
    request.expiry += 1.u256
    let item1 = SlotQueueItem.init(request, 1)
    check item1 < item0

  test "sorts items by slot size ascending (smaller dataset = higher priority)":
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0)
    request.ask.slotSize -= 1.u256
    let item1 = SlotQueueItem.init(request, 1)
    check item1 < item0

  test "should call callback once an item is added":
    newSlotQueue(maxSize = 2, maxWorkers = 2)
    let item = SlotQueueItem.example
    check not onProcessSlotCalled
    check queue.push(item).isOk
    check eventually onProcessSlotCalled

  test "should only process item once":
    newSlotQueue(maxSize = 2, maxWorkers = 2)
    let item = SlotQueueItem.example
    check queue.push(item).isOk
    check eventually onProcessSlotCalledWith == @[(item.requestId, item.slotIndex)]

  test "should process items in correct order":
    newSlotQueue(maxSize = 2, maxWorkers = 2)
    # sleeping after push allows the slotqueue loop to iterate,
    # calling the callback for each pushed/updated item
    var request = StorageRequest.example
    let item0 = SlotQueueItem.init(request, 0)
    request.ask.reward += 1.u256
    let item1 = SlotQueueItem.init(request, 1)
    request.ask.reward += 1.u256
    let item2 = SlotQueueItem.init(request, 2)
    request.ask.reward += 1.u256
    let item3 = SlotQueueItem.init(request, 3)

    check queue.push(item0).isOk
    await sleepAsync(1.millis)
    check queue.push(item1).isOk
    await sleepAsync(1.millis)
    check queue.push(item2).isOk
    await sleepAsync(1.millis)
    check queue.push(item3).isOk

    check eventually (
      onProcessSlotCalledWith ==
      @[
        (item0.requestId, item0.slotIndex),
        (item1.requestId, item1.slotIndex),
        (item2.requestId, item2.slotIndex),
        (item3.requestId, item3.slotIndex),
      ]
    )

  test "processing a 'seen' item pauses the queue":
    newSlotQueue(maxSize = 4, maxWorkers = 4)
    let request = StorageRequest.example
    let item =
      SlotQueueItem.init(request.id, 0'u16, request.ask, request.expiry, seen = true)
    check queue.push(item).isOk
    check eventually queue.paused
    check onProcessSlotCalledWith.len == 0

  test "pushing items to queue unpauses queue":
    newSlotQueue(maxSize = 4, maxWorkers = 4)
    queue.pause

    let request = StorageRequest.example
    var items = SlotQueueItem.init(request)
    check queue.push(items).isOk
    # check all items processed
    check eventually queue.len == 0

  test "pushing seen item does not unpause queue":
    newSlotQueue(maxSize = 4, maxWorkers = 4)
    let request = StorageRequest.example
    let item0 =
      SlotQueueItem.init(request.id, 0'u16, request.ask, request.expiry, seen = true)
    check queue.paused
    check queue.push(item0).isOk
    check queue.paused

  test "paused queue waits for unpause before continuing processing":
    newSlotQueue(maxSize = 4, maxWorkers = 4)
    let request = StorageRequest.example
    let item =
      SlotQueueItem.init(request.id, 1'u16, request.ask, request.expiry, seen = false)
    check queue.paused
    # push causes unpause
    check queue.push(item).isOk
    # check all items processed
    check eventually onProcessSlotCalledWith == @[(item.requestId, item.slotIndex)]
    check eventually queue.len == 0

  test "item 'seen' flags can be cleared":
    newSlotQueue(maxSize = 4, maxWorkers = 1)
    let request = StorageRequest.example
    let item0 =
      SlotQueueItem.init(request.id, 0'u16, request.ask, request.expiry, seen = true)
    let item1 =
      SlotQueueItem.init(request.id, 1'u16, request.ask, request.expiry, seen = true)
    check queue.push(item0).isOk
    check queue.push(item1).isOk
    check queue[0].seen
    check queue[1].seen

    queue.clearSeenFlags()
    check queue[0].seen == false
    check queue[1].seen == false
