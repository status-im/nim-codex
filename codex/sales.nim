import std/sequtils
import std/sugar
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/datastore
import ./market
import ./clock
import ./stores
import ./contracts/requests
import ./contracts/marketplace
import ./logutils
import ./sales/salescontext
import ./sales/salesagent
import ./sales/statemachine
import ./sales/slotqueue
import ./sales/states/preparing
import ./sales/states/unknown
import ./utils/then
import ./utils/trackedfutures

## Sales holds a list of available storage that it may sell.
##
## When storage is requested on the market that matches availability, the Sales
## object will instruct the Codex node to persist the requested data. Once the
## data has been persisted, it uploads a proof of storage to the market in an
## attempt to win a storage contract.
##
##    Node                        Sales                   Market
##     |                          |                         |
##     | -- add availability  --> |                         |
##     |                          | <-- storage request --- |
##     | <----- store data ------ |                         |
##     | -----------------------> |                         |
##     |                          |                         |
##     | <----- prove data ----   |                         |
##     | -----------------------> |                         |
##     |                          | ---- storage proof ---> |

export stint
export reservations
export salesagent
export salescontext

logScope:
  topics = "sales marketplace"

type
  Sales* = ref object
    context*: SalesContext
    agents*: seq[SalesAgent]
    running: bool
    subscriptions: seq[market.Subscription]
    trackedFutures: TrackedFutures

proc `onStore=`*(sales: Sales, onStore: OnStore) =
  sales.context.onStore = some onStore

proc `onClear=`*(sales: Sales, onClear: OnClear) =
  sales.context.onClear = some onClear

proc `onSale=`*(sales: Sales, callback: OnSale) =
  sales.context.onSale = some callback

proc `onProve=`*(sales: Sales, callback: OnProve) =
  sales.context.onProve = some callback

proc `onExpiryUpdate=`*(sales: Sales, callback: OnExpiryUpdate) =
  sales.context.onExpiryUpdate = some callback

proc onStore*(sales: Sales): ?OnStore = sales.context.onStore

proc onClear*(sales: Sales): ?OnClear = sales.context.onClear

proc onSale*(sales: Sales): ?OnSale = sales.context.onSale

proc onProve*(sales: Sales): ?OnProve = sales.context.onProve

proc onExpiryUpdate*(sales: Sales): ?OnExpiryUpdate = sales.context.onExpiryUpdate

proc new*(_: type Sales,
          market: Market,
          clock: Clock,
          repo: RepoStore): Sales =
  Sales.new(market, clock, repo, 0)

proc new*(_: type Sales,
          market: Market,
          clock: Clock,
          repo: RepoStore,
          simulateProofFailures: int): Sales =

  let reservations = Reservations.new(repo)
  Sales(
    context: SalesContext(
      market: market,
      clock: clock,
      reservations: reservations,
      slotQueue: SlotQueue.new(),
      simulateProofFailures: simulateProofFailures
    ),
    trackedFutures: TrackedFutures.new(),
    subscriptions: @[]
  )

proc remove(sales: Sales, agent: SalesAgent) {.async.} =
  await agent.stop()
  if sales.running:
    sales.agents.keepItIf(it != agent)

proc cleanUp(sales: Sales,
             agent: SalesAgent,
             returnBytes: bool,
             reprocessSlot: bool,
             processing: Future[void]) {.async.} =

  let data = agent.data

  logScope:
    topics = "sales cleanUp"
    requestId = data.requestId
    slotIndex = data.slotIndex
    reservationId = data.reservation.?id |? ReservationId.default
    availabilityId = data.reservation.?availabilityId |? AvailabilityId.default

  trace "cleaning up sales agent"

  # if reservation for the SalesAgent was not created, then it means
  # that the cleanUp was called before the sales process really started, so
  # there are not really any bytes to be returned
  if returnBytes and request =? data.request and reservation =? data.reservation:
    if returnErr =? (await sales.context.reservations.returnBytesToAvailability(
                        reservation.availabilityId,
                        reservation.id,
                        request.ask.slotSize
                      )).errorOption:
          error "failure returning bytes",
            error = returnErr.msg,
            bytes = request.ask.slotSize

  # delete reservation and return reservation bytes back to the availability
  if reservation =? data.reservation and
     deleteErr =? (await sales.context.reservations.deleteReservation(
                    reservation.id,
                    reservation.availabilityId
                  )).errorOption:
      error "failure deleting reservation", error = deleteErr.msg

  # Re-add items back into the queue to prevent small availabilities from
  # draining the queue. Seen items will be ordered last.
  if reprocessSlot and request =? data.request:
    let queue = sales.context.slotQueue
    var seenItem = SlotQueueItem.init(data.requestId,
                                      data.slotIndex.truncate(uint16),
                                      data.ask,
                                      request.expiry,
                                      seen = true)
    trace "pushing ignored item to queue, marked as seen"
    if err =? queue.push(seenItem).errorOption:
      error "failed to readd slot to queue",
        errorType = $(type err), error = err.msg

  await sales.remove(agent)

  # signal back to the slot queue to cycle a worker
  if not processing.isNil and not processing.finished():
    processing.complete()

proc filled(
  sales: Sales,
  request: StorageRequest,
  slotIndex: UInt256,
  processing: Future[void]) =

  if onSale =? sales.context.onSale:
    onSale(request, slotIndex)

  # signal back to the slot queue to cycle a worker
  if not processing.isNil and not processing.finished():
    processing.complete()

proc processSlot(sales: Sales, item: SlotQueueItem, done: Future[void]) =
  debug "Processing slot from queue", requestId = item.requestId,
    slot = item.slotIndex

  let agent = newSalesAgent(
    sales.context,
    item.requestId,
    item.slotIndex.u256,
    none StorageRequest
  )

  agent.onCleanUp = proc (returnBytes = false, reprocessSlot = false) {.async.} =
    await sales.cleanUp(agent, returnBytes, reprocessSlot, done)

  agent.onFilled = some proc(request: StorageRequest, slotIndex: UInt256) =
    sales.filled(request, slotIndex, done)

  agent.start(SalePreparing())
  sales.agents.add agent

proc deleteInactiveReservations(sales: Sales, activeSlots: seq[Slot]) {.async.} =
  let reservations = sales.context.reservations
  without reservs =? await reservations.all(Reservation):
    return

  let unused = reservs.filter(r => (
    let slotId = slotId(r.requestId, r.slotIndex)
    not activeSlots.any(slot => slot.id == slotId)
  ))

  if unused.len == 0:
    return

  info "Found unused reservations for deletion", unused = unused.len

  for reservation in unused:

    logScope:
      reservationId = reservation.id
      availabilityId = reservation.availabilityId

    if err =? (await reservations.deleteReservation(
      reservation.id, reservation.availabilityId
    )).errorOption:
      error "Failed to delete unused reservation", error = err.msg
    else:
      trace "Deleted unused reservation"

proc mySlots*(sales: Sales): Future[seq[Slot]] {.async.} =
  let market = sales.context.market
  let slotIds = await market.mySlots()
  var slots: seq[Slot] = @[]

  info "Loading active slots", slotsCount = len(slots)
  for slotId in slotIds:
    if slot =? (await market.getActiveSlot(slotId)):
      slots.add slot

  return slots

proc activeSale*(sales: Sales, slotId: SlotId): Future[?SalesAgent] {.async.} =
  for agent in sales.agents:
    if slotId(agent.data.requestId, agent.data.slotIndex) == slotId:
      return some agent

  return none SalesAgent

proc load*(sales: Sales) {.async.} =
  let activeSlots = await sales.mySlots()

  await sales.deleteInactiveReservations(activeSlots)

  for slot in activeSlots:
    let agent = newSalesAgent(
      sales.context,
      slot.request.id,
      slot.slotIndex,
      some slot.request)

    agent.onCleanUp = proc(returnBytes = false, reprocessSlot = false) {.async.} =
      # since workers are not being dispatched, this future has not been created
      # by a worker. Create a dummy one here so we can call sales.cleanUp
      let done: Future[void] = nil
      await sales.cleanUp(agent, returnBytes, reprocessSlot, done)

    # There is no need to assign agent.onFilled as slots loaded from `mySlots`
    # are inherently already filled and so assigning agent.onFilled would be
    # superfluous.

    agent.start(SaleUnknown())
    sales.agents.add agent

proc onAvailabilityAdded(sales: Sales, availability: Availability) {.async.} =
  ## When availabilities are modified or added, the queue should be unpaused if
  ## it was paused and any slots in the queue should have their `seen` flag
  ## cleared.
  let queue = sales.context.slotQueue

  queue.clearSeenFlags()
  if queue.paused:
    trace "unpausing queue after new availability added"
    queue.unpause()

proc onStorageRequested(sales: Sales,
                        requestId: RequestId,
                        ask: StorageAsk,
                        expiry: UInt256) =

  logScope:
    topics = "marketplace sales onStorageRequested"
    requestId
    slots = ask.slots
    expiry

  let slotQueue = sales.context.slotQueue

  trace "storage requested, adding slots to queue"

  without items =? SlotQueueItem.init(requestId, ask, expiry).catch, err:
    if err of SlotsOutOfRangeError:
      warn "Too many slots, cannot add to queue"
    else:
      warn "Failed to create slot queue items from request", error = err.msg
    return

  for item in items:
    # continue on failure
    if err =? slotQueue.push(item).errorOption:
      if err of SlotQueueItemExistsError:
        error "Failed to push item to queue becaue it already exists"
      elif err of QueueNotRunningError:
        warn "Failed to push item to queue becaue queue is not running"
      else:
        warn "Error adding request to SlotQueue", error = err.msg

proc onSlotFreed(sales: Sales,
                 requestId: RequestId,
                 slotIndex: UInt256) =

  logScope:
    topics = "marketplace sales onSlotFreed"
    requestId
    slotIndex

  trace "slot freed, adding to queue"

  proc addSlotToQueue() {.async.} =
    let context = sales.context
    let market = context.market
    let queue = context.slotQueue

    # first attempt to populate request using existing slot metadata in queue
    without var found =? queue.populateItem(requestId,
                                            slotIndex.truncate(uint16)):
      trace "no existing request metadata, getting request info from contract"
      # if there's no existing slot for that request, retrieve the request
      # from the contract.
      without request =? await market.getRequest(requestId):
        error "unknown request in contract"
        return

      found = SlotQueueItem.init(request, slotIndex.truncate(uint16))

    if err =? queue.push(found).errorOption:
      raise err

  addSlotToQueue()
    .track(sales)
    .catch(proc(err: ref CatchableError) =
      if err of SlotQueueItemExistsError:
        error "Failed to push item to queue becaue it already exists"
      elif err of QueueNotRunningError:
        warn "Failed to push item to queue becaue queue is not running"
      else:
        warn "Error adding request to SlotQueue", error = err.msg
    )

proc subscribeRequested(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market

  proc onStorageRequested(requestId: RequestId,
                          ask: StorageAsk,
                          expiry: UInt256) =
    sales.onStorageRequested(requestId, ask, expiry)

  try:
    let sub = await market.subscribeRequests(onStorageRequested)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to storage request events", msg = e.msg

proc subscribeCancellation(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  proc onCancelled(requestId: RequestId) =
    trace "request cancelled (via contract RequestCancelled event), removing all request slots from queue"
    queue.delete(requestId)

  try:
    let sub = await market.subscribeRequestCancelled(onCancelled)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to cancellation events", msg = e.msg

proc subscribeFulfilled*(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  proc onFulfilled(requestId: RequestId) =
    trace "request fulfilled, removing all request slots from queue"
    queue.delete(requestId)

    for agent in sales.agents:
      agent.onFulfilled(requestId)

  try:
    let sub = await market.subscribeFulfillment(onFulfilled)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to storage fulfilled events", msg = e.msg

proc subscribeFailure(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  proc onFailed(requestId: RequestId) =
    trace "request failed, removing all request slots from queue"
    queue.delete(requestId)

    for agent in sales.agents:
      agent.onFailed(requestId)

  try:
    let sub = await market.subscribeRequestFailed(onFailed)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to storage failure events", msg = e.msg

proc subscribeSlotFilled(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
    trace "slot filled, removing from slot queue", requestId, slotIndex
    queue.delete(requestId, slotIndex.truncate(uint16))

    for agent in sales.agents:
      agent.onSlotFilled(requestId, slotIndex)

  try:
    let sub = await market.subscribeSlotFilled(onSlotFilled)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to slot filled events", msg = e.msg

proc subscribeSlotFreed(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market

  proc onSlotFreed(requestId: RequestId, slotIndex: UInt256) =
    sales.onSlotFreed(requestId, slotIndex)

  try:
    let sub = await market.subscribeSlotFreed(onSlotFreed)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to slot freed events", msg = e.msg

proc subscribeSlotReservationsFull(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  proc onSlotReservationsFull(requestId: RequestId, slotIndex: UInt256) =
    trace "reservations for slot full, removing from slot queue", requestId, slotIndex
    queue.delete(requestId, slotIndex.truncate(uint16))

  try:
    let sub = await market.subscribeSlotReservationsFull(onSlotReservationsFull)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to slot filled events", msg = e.msg

proc startSlotQueue(sales: Sales) {.async.} =
  let slotQueue = sales.context.slotQueue
  let reservations = sales.context.reservations

  slotQueue.onProcessSlot =
    proc(item: SlotQueueItem, done: Future[void]) {.async.} =
      trace "processing slot queue item", reqId = item.requestId, slotIdx = item.slotIndex
      sales.processSlot(item, done)

  asyncSpawn slotQueue.start()

  proc onAvailabilityAdded(availability: Availability) {.async.} =
    await sales.onAvailabilityAdded(availability)

  reservations.onAvailabilityAdded = onAvailabilityAdded

proc subscribe(sales: Sales) {.async.} =
  await sales.subscribeRequested()
  await sales.subscribeFulfilled()
  await sales.subscribeFailure()
  await sales.subscribeSlotFilled()
  await sales.subscribeSlotFreed()
  await sales.subscribeCancellation()
  await sales.subscribeSlotReservationsFull()

proc unsubscribe(sales: Sales) {.async.} =
  for sub in sales.subscriptions:
    try:
      await sub.unsubscribe()
    except CancelledError as error:
      raise error
    except CatchableError as e:
      error "Unable to unsubscribe from subscription", error = e.msg

proc start*(sales: Sales) {.async.} =
  await sales.load()
  await sales.startSlotQueue()
  await sales.subscribe()
  sales.running = true

proc stop*(sales: Sales) {.async.} =
  trace "stopping sales"
  sales.running = false
  await sales.context.slotQueue.stop()
  await sales.unsubscribe()
  await sales.trackedFutures.cancelTracked()

  for agent in sales.agents:
    await agent.stop()

  sales.agents = @[]
