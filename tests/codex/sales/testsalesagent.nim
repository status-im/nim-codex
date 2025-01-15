import std/times
import pkg/chronos
import pkg/codex/sales
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/sales/statemachine
import pkg/codex/sales/states/errorhandling

import ../../asynctest
import ../helpers/mockmarket
import ../helpers/mockclock
import ../helpers
import ../examples

var onCancelCalled = false
var onFailedCalled = false
var onSlotFilledCalled = false
var onErrorCalled = false

type
  MockState = ref object of SaleState
  MockErrorState = ref object of ErrorHandlingState

method `$`*(state: MockState): string =
  "MockState"

method `$`*(state: MockErrorState): string =
  "MockErrorState"

method onCancelled*(state: MockState, request: StorageRequest): ?State =
  onCancelCalled = true

method onFailed*(state: MockState, request: StorageRequest): ?State =
  onFailedCalled = true

method onSlotFilled*(
    state: MockState, requestId: RequestId, slotIndex: UInt256
): ?State =
  onSlotFilledCalled = true

method onError*(state: MockErrorState, err: ref CatchableError): ?State =
  onErrorCalled = true

method run*(state: MockErrorState, machine: Machine): Future[?State] {.async.} =
  raise newException(ValueError, "failure")

asyncchecksuite "Sales agent":
  let request = StorageRequest.example
  var agent: SalesAgent
  var context: SalesContext
  var slotIndex: UInt256
  var market: MockMarket
  var clock: MockClock

  setup:
    market = MockMarket.new()
    market.requestExpiry[request.id] =
      getTime().toUnix() + request.expiry.truncate(int64)
    clock = MockClock.new()
    context = SalesContext(market: market, clock: clock)
    slotIndex = 0.u256
    onCancelCalled = false
    onFailedCalled = false
    onSlotFilledCalled = false
    agent = newSalesAgent(context, request.id, slotIndex, some request)

  teardown:
    await agent.stop()

  test "can retrieve request":
    agent = newSalesAgent(context, request.id, slotIndex, none StorageRequest)
    market.requested = @[request]
    await agent.retrieveRequest()
    check agent.data.request == some request

  test "subscribe assigns cancelled future":
    await agent.subscribe()
    check not agent.data.cancelled.isNil

  test "unsubscribe deassigns canceleld future":
    await agent.subscribe()
    await agent.unsubscribe()
    check agent.data.cancelled.isNil

  test "subscribe can be called multiple times, without overwriting subscriptions/futures":
    await agent.subscribe()
    let cancelled = agent.data.cancelled
    await agent.subscribe()
    check cancelled == agent.data.cancelled

  test "unsubscribe can be called multiple times":
    await agent.subscribe()
    await agent.unsubscribe()
    await agent.unsubscribe()

  test "current state onCancelled called when cancel emitted":
    agent.start(MockState.new())
    await agent.subscribe()
    market.requestState[request.id] = RequestState.Cancelled
    clock.set(market.requestExpiry[request.id] + 1)
    check eventually onCancelCalled

  for requestState in {
    RequestState.New, RequestState.Started, RequestState.Finished, RequestState.Failed
  }:
    test "onCancelled is not called when request state is " & $requestState:
      agent.start(MockState.new())
      await agent.subscribe()
      market.requestState[request.id] = requestState
      clock.set(market.requestExpiry[request.id] + 1)
      await sleepAsync(100.millis)
      check not onCancelCalled

  for requestState in {RequestState.Started, RequestState.Finished, RequestState.Failed}:
    test "cancelled future is finished when request state is " & $requestState:
      agent.start(MockState.new())
      await agent.subscribe()
      market.requestState[request.id] = requestState
      clock.set(market.requestExpiry[request.id] + 1)
      check eventually agent.data.cancelled.finished

  test "cancelled future is finished (cancelled) when onFulfilled called":
    agent.start(MockState.new())
    await agent.subscribe()
    agent.onFulfilled(request.id)
    check eventually agent.data.cancelled.cancelled()

  test "current state onFailed called when onFailed called":
    agent.start(MockState.new())
    agent.onFailed(request.id)
    check eventually onFailedCalled

  test "current state onSlotFilled called when slot filled emitted":
    agent.start(MockState.new())
    agent.onSlotFilled(request.id, slotIndex)
    check eventually onSlotFilledCalled

  test "ErrorHandlingState.onError can be overridden at the state level":
    agent.start(MockErrorState.new())
    check eventually onErrorCalled
