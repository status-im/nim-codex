import pkg/asynctest
import pkg/chronos
import pkg/codex/sales
import ./helpers/mockmarket
import ./helpers/mockclock
import ./examples

suite "Sales":

  let availability = Availability.init(
    size=100.u256,
    duration=60.u256,
    minPrice=42.u256
  )
  var request = StorageRequest(
    ask: StorageAsk(
      duration: 60.u256,
      size: 100.u256,
      reward:42.u256,
      slots: 4
    ),
    content: StorageContent(
      cid: "some cid"
    )
  )
  let proof = seq[byte].example

  var sales: Sales
  var market: MockMarket
  var clock: MockClock

  setup:
    market = MockMarket.new()
    clock = MockClock.new()
    sales = Sales.new(market, clock)
    sales.onStore = proc(cid: string, availability: Availability) {.async.} =
      discard
    sales.onProve = proc(cid: string): Future[seq[byte]] {.async.} =
      return proof
    await sales.start()
    request.expiry = (clock.now() + 42).u256

  teardown:
    await sales.stop()

  test "has no availability initially":
    check sales.available.len == 0

  test "can add available storage":
    let availability1 = Availability.example
    let availability2 = Availability.example
    sales.add(availability1)
    check sales.available.contains(availability1)
    sales.add(availability2)
    check sales.available.contains(availability1)
    check sales.available.contains(availability2)

  test "can remove available storage":
    sales.add(availability)
    sales.remove(availability)
    check sales.available.len == 0

  test "generates unique ids for storage availability":
    let availability1 = Availability.init(1.u256, 2.u256, 3.u256)
    let availability2 = Availability.init(1.u256, 2.u256, 3.u256)
    check availability1.id != availability2.id

  test "makes storage unavailable when matching request comes in":
    sales.add(availability)
    discard await market.requestStorage(request)
    check sales.available.len == 0

  test "ignores request when no matching storage is available":
    sales.add(availability)
    var tooBig = request
    tooBig.ask.size = request.ask.size + 1
    discard await market.requestStorage(tooBig)
    check sales.available == @[availability]

  test "retrieves and stores data locally":
    var storingCid: string
    var storingAvailability: Availability
    sales.onStore = proc(cid: string, availability: Availability) {.async.} =
      storingCid = cid
      storingAvailability = availability
    sales.add(availability)
    discard await market.requestStorage(request)
    check storingCid == request.content.cid

  test "makes storage available again when data retrieval fails":
    let error = newException(IOError, "data retrieval failed")
    sales.onStore = proc(cid: string, availability: Availability) {.async.} =
      raise error
    sales.add(availability)
    discard await market.requestStorage(request)
    check sales.available == @[availability]

  test "generates proof of storage":
    var provingCid: string
    sales.onProve = proc(cid: string): Future[seq[byte]] {.async.} = provingCid = cid
    sales.add(availability)
    discard await market.requestStorage(request)
    check provingCid == request.content.cid

  test "fills a slot":
    sales.add(availability)
    discard await market.requestStorage(request)
    check market.filled.len == 1
    check market.filled[0].requestId == request.id
    check market.filled[0].slotIndex < request.ask.slots.u256
    check market.filled[0].proof == proof
    check market.filled[0].host == await market.getSigner()

  test "calls onSale when slot is filled":
    var soldAvailability: Availability
    var soldRequest: StorageRequest
    var soldSlotIndex: UInt256
    sales.onSale = proc(availability: Availability,
                        request: StorageRequest,
                        slotIndex: UInt256) =
      soldAvailability = availability
      soldRequest = request
      soldSlotIndex = slotIndex
    sales.add(availability)
    discard await market.requestStorage(request)
    check soldAvailability == availability
    check soldRequest == request
    check soldSlotIndex < request.ask.slots.u256

  test "calls onClear when storage becomes available again":
    sales.onProve = proc(cid: string): Future[seq[byte]] {.async.} =
      raise newException(IOError, "proof failed")
    var clearedAvailability: Availability
    var clearedRequest: StorageRequest
    sales.onClear = proc(availability: Availability, request: StorageRequest) =
      clearedAvailability = availability
      clearedRequest = request
    sales.add(availability)
    discard await market.requestStorage(request)
    check clearedAvailability == availability
    check clearedRequest == request

  test "makes storage available again when other host fills the slot":
    let otherHost = Address.example
    sales.onStore = proc(cid: string, availability: Availability) {.async.} =
      await sleepAsync(1.hours)
    sales.add(availability)
    discard await market.requestStorage(request)
    for slotIndex in 0..<request.ask.slots:
      market.fillSlot(request.id, slotIndex.u256, proof, otherHost)
    check sales.available == @[availability]

  test "makes storage available again when request expires":
    sales.onStore = proc(cid: string, availability: Availability) {.async.} =
      await sleepAsync(1.hours)
    sales.add(availability)
    discard await market.requestStorage(request)
    clock.set(request.expiry.truncate(int64))
    await sleepAsync(2.seconds)
    check sales.available == @[availability]
