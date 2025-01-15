import pkg/questionable/results

import pkg/codex/clock
import pkg/codex/contracts/requests
import pkg/codex/sales
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/sales/states/filled
import pkg/codex/sales/states/errored
import pkg/codex/sales/states/proving

import ../../../asynctest
import ../../helpers/mockmarket
import ../../examples
import ../../helpers

checksuite "sales state 'filled'":
  let request = StorageRequest.example
  let slotIndex = (request.ask.slots div 2).u256

  var market: MockMarket
  var slot: MockSlot
  var agent: SalesAgent
  var state: SaleFilled
  var onExpiryUpdatePassedExpiry: SecondsSince1970

  setup:
    market = MockMarket.new()
    slot = MockSlot(
      requestId: request.id,
      host: Address.example,
      slotIndex: slotIndex,
      proof: Groth16Proof.default,
    )

    market.requestEnds[request.id] = 321
    onExpiryUpdatePassedExpiry = -1
    let onExpiryUpdate = proc(
        rootCid: string, expiry: SecondsSince1970
    ): Future[?!void] {.async.} =
      onExpiryUpdatePassedExpiry = expiry
      return success()
    let context = SalesContext(market: market, onExpiryUpdate: some onExpiryUpdate)

    agent = newSalesAgent(context, request.id, slotIndex, some request)
    state = SaleFilled.new()

  test "switches to proving state when slot is filled by me":
    slot.host = await market.getSigner()
    market.filled = @[slot]
    let next = await state.run(agent)
    check !next of SaleProving

  test "calls onExpiryUpdate with request end":
    slot.host = await market.getSigner()
    market.filled = @[slot]

    let expectedExpiry = 123
    market.requestEnds[request.id] = expectedExpiry
    let next = await state.run(agent)
    check !next of SaleProving
    check onExpiryUpdatePassedExpiry == expectedExpiry

  test "switches to error state when slot is filled by another host":
    slot.host = Address.example
    market.filled = @[slot]
    let next = await state.run(agent)
    check !next of SaleErrored
