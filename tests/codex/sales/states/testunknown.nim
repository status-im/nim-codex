import pkg/asynctest
import pkg/codex/contracts/requests
import pkg/codex/sales
import pkg/codex/sales/states/unknown
import pkg/codex/sales/states/errored
import pkg/codex/sales/states/filled
import pkg/codex/sales/states/finished
import pkg/codex/sales/states/failed
import ../../helpers/mockmarket
import ../../examples

suite "sales state 'unknown'":

  let request = StorageRequest.example
  let slotIndex = (request.ask.slots div 2).u256
  let slotId = slotId(request.id, slotIndex)

  var market: MockMarket
  var sales: Sales
  var agent: SalesAgent
  var state: SaleUnknown

  setup:
    market = MockMarket.new()
    sales = Sales.new(market, nil, nil)
    agent = sales.newSalesAgent(request.id,
                                slotIndex,
                                Availability.none,
                                StorageRequest.none)
    state = SaleUnknown.new()

  test "switches to error state when on chain state cannot be fetched":
    let next = await state.run(agent)
    check !next of SaleErrored

  test "switches to error state when on chain state is 'free'":
    market.slotState[slotId] = SlotState.Free
    let next = await state.run(agent)
    check !next of SaleErrored

  test "switches to filled state when on chain state is 'filled'":
    market.slotState[slotId] = SlotState.Filled
    let next = await state.run(agent)
    check !next of SaleFilled

  test "switches to finished state when on chain state is 'finished'":
    market.slotState[slotId] = SlotState.Finished
    let next = await state.run(agent)
    check !next of SaleFinished

  test "switches to finished state when on chain state is 'paid'":
    market.slotState[slotId] = SlotState.Paid
    let next = await state.run(agent)
    check !next of SaleFinished

  test "switches to failed state when on chain state is 'failed'":
    market.slotState[slotId] = SlotState.Failed
    let next = await state.run(agent)
    check !next of SaleFailed
