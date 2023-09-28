import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/upraises
import ../contracts/requests
import ../errors
import ./statemachine
import ./salescontext
import ./salesdata
import ./reservations

export reservations

logScope:
  topics = "marketplace sales"

type
  SalesAgent* = ref object of Machine
    context*: SalesContext
    data*: SalesData
    subscribed: bool
    # Slot-level callbacks. Ensures that any slot/agent-level closure (such as
    # `done` futures) are not overwritten each time a slot is processed.
    onCleanUp*: OnCleanUp
    onFilled*: ?OnFilled

  OnCleanUp* = proc: Future[void] {.gcsafe, upraises: [].}
  OnFilled* = proc(request: StorageRequest,
                   slotIndex: UInt256) {.gcsafe, upraises: [].}

  SalesAgentError = object of CodexError
  AllSlotsFilledError* = object of SalesAgentError

func `==`*(a, b: SalesAgent): bool =
  a.data.requestId == b.data.requestId and
  a.data.slotIndex == b.data.slotIndex

proc newSalesAgent*(context: SalesContext,
                    requestId: RequestId,
                    slotIndex: UInt256,
                    request: ?StorageRequest): SalesAgent =
  var agent = SalesAgent.new()
  agent.context = context
  agent.data = SalesData(
                requestId: requestId,
                slotIndex: slotIndex,
                request: request)
  return agent

proc retrieveRequest*(agent: SalesAgent) {.async.} =
  let data = agent.data
  let market = agent.context.market
  if data.request.isNone:
    data.request = await market.getRequest(data.requestId)

proc subscribeCancellation(agent: SalesAgent) {.async.} =
  let data = agent.data
  let clock = agent.context.clock

  proc onCancelled() {.async.} =
    without request =? data.request:
      return

    await clock.waitUntil(request.expiry.truncate(int64))
    agent.schedule(cancelledEvent(request))

  data.cancelled = onCancelled()

method onFulfilled*(agent: SalesAgent, requestId: RequestId) {.base, gcsafe, upraises: [].} =
  if agent.data.requestId == requestId and
     not agent.data.cancelled.isNil:
    agent.data.cancelled.cancel()

method onFailed*(agent: SalesAgent, requestId: RequestId) {.base, gcsafe, upraises: [].} =
  without request =? agent.data.request:
    return
  if agent.data.requestId == requestId:
    agent.schedule(failedEvent(request))

method onSlotFilled*(agent: SalesAgent,
                     requestId: RequestId,
                     slotIndex: UInt256) {.base, gcsafe, upraises: [].} =

  if agent.data.requestId == requestId and
     agent.data.slotIndex == slotIndex:
    agent.schedule(slotFilledEvent(requestId, slotIndex))

proc subscribe*(agent: SalesAgent) {.async.} =
  if agent.subscribed:
    return

  await agent.subscribeCancellation()
  agent.subscribed = true

proc unsubscribe*(agent: SalesAgent) {.async.} =
  if not agent.subscribed:
    return

  let data = agent.data
  if not data.cancelled.isNil and not data.cancelled.finished:
    await data.cancelled.cancelAndWait()
    data.cancelled = nil

  agent.subscribed = false

proc stop*(agent: SalesAgent) {.async.} =
  await Machine(agent).stop()
  await agent.unsubscribe()
