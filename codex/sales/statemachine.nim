import std/sequtils
import pkg/chronos
import pkg/questionable
import pkg/upraises
import ../errors
import ../utils/asyncstatemachine
import ../market
import ../clock
import ../proving
import ../contracts/requests

export market
export clock
export asyncstatemachine
export proving

type
  Sales* = ref object
    context*: SalesContext
    subscription*: ?market.Subscription
    available: seq[Availability]
    agents*: seq[SalesAgent]
  SalesContext* = ref object
    market*: Market
    clock*: Clock
    onStore*: ?OnStore
    onProve*: ?OnProve
    onClear*: ?OnClear
    onSale*: ?OnSale
    onSaleFailed*: ?OnSaleFailed
    proving*: Proving
  SalesData* = ref object
    requestId*: RequestId
    ask*: StorageAsk
    availability*: ?Availability # TODO: when availability persistence is added, change this to not optional
    request*: ?StorageRequest
    slotIndex*: UInt256
    failed*: market.Subscription
    fulfilled*: market.Subscription
    slotFilled*: market.Subscription
    cancelled*: Future[void]
  SalesAgent* = ref object of Machine
    context*: SalesContext
    data*: SalesData
  SaleState* = ref object of State
  SaleError* = ref object of CodexError
  Availability* = object
    id*: array[32, byte]
    size*: UInt256
    duration*: UInt256
    minPrice*: UInt256
  AvailabilityChange* = proc(availability: Availability) {.gcsafe, upraises: [].}
  # TODO: when availability changes introduced, make availability non-optional (if we need to keep it at all)
  RequestEvent* = proc(state: SaleState, request: StorageRequest): Future[void] {.gcsafe, upraises: [].}
  OnStore* = proc(request: StorageRequest,
                  slot: UInt256,
                  availability: ?Availability): Future[void] {.gcsafe, upraises: [].}
  OnProve* = proc(request: StorageRequest,
                  slot: UInt256): Future[seq[byte]] {.gcsafe, upraises: [].}
  OnClear* = proc(availability: ?Availability,# TODO: when availability changes introduced, make availability non-optional (if we need to keep it at all)
                  request: StorageRequest,
                  slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnSale* = proc(availability: ?Availability, # TODO: when availability changes introduced, make availability non-optional (if we need to keep it at all)
                 request: StorageRequest,
                 slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnSaleFailed* = proc(availability: Availability) {.gcsafe, upraises: [].}

proc `onStore=`*(sales: Sales, onStore: OnStore) =
  sales.context.onStore = some onStore

proc `onProve=`*(sales: Sales, onProve: OnProve) =
  sales.context.onProve = some onProve

proc `onClear=`*(sales: Sales, onClear: OnClear) =
  sales.context.onClear = some onClear

proc `onSale=`*(sales: Sales, callback: OnSale) =
  sales.context.onSale = some callback

proc onStore*(sales: Sales): ?OnStore = sales.context.onStore

proc onProve*(sales: Sales): ?OnProve = sales.context.onProve

proc onClear*(sales: Sales): ?OnClear = sales.context.onClear

proc onSale*(sales: Sales): ?OnSale = sales.context.onSale

proc available*(sales: Sales): seq[Availability] = sales.available

func add*(sales: Sales, availability: Availability) =
  if not sales.available.contains(availability):
    sales.available.add(availability)
  # TODO: add to disk (persist), serialise to json.

func remove*(sales: Sales, availability: Availability) =
  sales.available.keepItIf(it != availability)
  # TODO: remove from disk availability, mark as in use by assigning
  # a slotId, so that it can be used for restoration (node restart)

func findAvailability*(sales: Sales, ask: StorageAsk): ?Availability =
  for availability in sales.available:
    if ask.slotSize <= availability.size and
       ask.duration <= availability.duration and
       ask.pricePerSlot >= availability.minPrice:
      return some availability

method onCancelled*(state: SaleState, request: StorageRequest): ?State {.base, upraises:[].} =
  discard

method onFailed*(state: SaleState, request: StorageRequest): ?State {.base, upraises:[].} =
  discard

method onSlotFilled*(state: SaleState, requestId: RequestId,
                     slotIndex: UInt256): ?State {.base, upraises:[].} =
  discard

proc cancelledEvent*(request: StorageRequest): Event =
  return proc (state: State): ?State =
    SaleState(state).onCancelled(request)

proc failedEvent*(request: StorageRequest): Event =
  return proc (state: State): ?State =
    SaleState(state).onFailed(request)

proc slotFilledEvent*(requestId: RequestId, slotIndex: UInt256): Event =
  return proc (state: State): ?State =
    SaleState(state).onSlotFilled(requestId, slotIndex)
