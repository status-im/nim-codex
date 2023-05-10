import std/sequtils
import pkg/questionable
import pkg/upraises
import pkg/stint
import pkg/chronicles
import pkg/datastore
import ./market
import ./clock
import ./proving
import ./stores
import ./contracts/requests
import ./sales/salescontext
import ./sales/salesagent
import ./sales/statemachine
import ./sales/states/preparing
import ./sales/states/unknown

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

logScope:
  topics = "sales"

type
  Sales* = ref object
    context*: SalesContext
    subscription*: ?market.Subscription
    agents*: seq[SalesAgent]

proc `onStore=`*(sales: Sales, onStore: OnStore) =
  sales.context.onStore = some onStore

proc `onClear=`*(sales: Sales, onClear: OnClear) =
  sales.context.onClear = some onClear

proc `onSale=`*(sales: Sales, callback: OnSale) =
  sales.context.onSale = some callback

proc onStore*(sales: Sales): ?OnStore = sales.context.onStore

proc onClear*(sales: Sales): ?OnClear = sales.context.onClear

proc onSale*(sales: Sales): ?OnSale = sales.context.onSale

func new*(_: type Sales,
          market: Market,
          clock: Clock,
          proving: Proving,
          repo: RepoStore): Sales =

  Sales(context: SalesContext(
    market: market,
    clock: clock,
    proving: proving,
    reservations: Reservations.new(repo)
  ))

proc remove(sales: Sales, agent: SalesAgent): OnCleanUp =
  proc(): Future[void] {.gcsafe, upraises:[], async.} =
    await agent.stop()
    sales.agents.keepItIf(it != agent)

proc handleRequest(sales: Sales,
                   requestId: RequestId,
                   ask: StorageAsk) =

  debug "handling storage requested",
    slots = ask.slots, slotSize = ask.slotSize, duration = ask.duration,
    reward = ask.reward, maxSlotLoss = ask.maxSlotLoss

  let agent = newSalesAgent(
    sales.context,
    requestId,
    none UInt256,
    none StorageRequest
  )

  agent.context.onStartOver =
    proc(slotIndex: UInt256) {.gcsafe, upraises:[], async.} =
      await agent.stop()
      agent.start(SalePreparing(ignoreSlotIndex: some slotIndex))

  agent.context.onCleanUp = sales.remove(agent)

  agent.start(SalePreparing())
  sales.agents.add agent

proc load*(sales: Sales) {.async.} =
  let market = sales.context.market

  let slotIds = await market.mySlots()

  for slotId in slotIds:
    if slot =? (await market.getActiveSlot(slotId)):
      let agent = newSalesAgent(
        sales.context,
        slot.request.id,
        some slot.slotIndex,
        some slot.request)

      agent.context.onCleanUp = sales.remove(agent)

      agent.start(SaleUnknown())
      sales.agents.add agent

proc start*(sales: Sales) {.async.} =
  doAssert sales.subscription.isNone, "Sales already started"

  proc onRequest(requestId: RequestId, ask: StorageAsk) {.gcsafe, upraises:[].} =
    sales.handleRequest(requestId, ask)

  try:
    sales.subscription = some await sales.context.market.subscribeRequests(onRequest)
  except CatchableError as e:
    error "Unable to start sales", msg = e.msg

proc stop*(sales: Sales) {.async.} =
  if subscription =? sales.subscription:
    sales.subscription = market.Subscription.none
    try:
      await subscription.unsubscribe()
    except CatchableError as e:
      warn "Unsubscribe failed", msg = e.msg

  for agent in sales.agents:
    await agent.stop()
