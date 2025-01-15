import pkg/chronos
import pkg/questionable
import pkg/codex/contracts/requests
import pkg/codex/sales/states/slotreserving
import pkg/codex/sales/states/downloading
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/failed
import pkg/codex/sales/states/ignored
import pkg/codex/sales/states/errored
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/sales/reservations
import pkg/codex/stores/repostore
import ../../../asynctest
import ../../helpers
import ../../examples
import ../../helpers/mockmarket
import ../../helpers/mockclock

asyncchecksuite "sales state 'SlotReserving'":
  let request = StorageRequest.example
  let slotIndex = (request.ask.slots div 2).u256
  var market: MockMarket
  var clock: MockClock
  var agent: SalesAgent
  var state: SaleSlotReserving
  var context: SalesContext

  setup:
    market = MockMarket.new()
    clock = MockClock.new()

    state = SaleSlotReserving.new()
    context = SalesContext(market: market, clock: clock)

    agent = newSalesAgent(context, request.id, slotIndex, request.some)

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "run switches to downloading when slot successfully reserved":
    let next = await state.run(agent)
    check !next of SaleDownloading

  test "run switches to ignored when slot reservation not allowed":
    market.setCanReserveSlot(false)
    let next = await state.run(agent)
    check !next of SaleIgnored

  test "run switches to errored when slot reservation errors":
    let error = newException(MarketError, "some error")
    market.setReserveSlotThrowError(some error)
    let next = !(await state.run(agent))
    check next of SaleErrored
    let errored = SaleErrored(next)
    check errored.error == error
