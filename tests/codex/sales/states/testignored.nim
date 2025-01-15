import pkg/questionable
import pkg/chronos
import pkg/codex/contracts/requests
import pkg/codex/sales/states/ignored
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/market

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../helpers/mockclock

asyncchecksuite "sales state 'ignored'":
  let request = StorageRequest.example
  let slotIndex = (request.ask.slots div 2).u256
  let market = MockMarket.new()
  let clock = MockClock.new()

  var state: SaleIgnored
  var agent: SalesAgent
  var returnBytesWas = false
  var reprocessSlotWas = false

  setup:
    let onCleanUp = proc(returnBytes = false, reprocessSlot = false) {.async.} =
      returnBytesWas = returnBytes
      reprocessSlotWas = reprocessSlot

    let context = SalesContext(market: market, clock: clock)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    agent.onCleanUp = onCleanUp
    state = SaleIgnored.new()

  test "calls onCleanUp with values assigned to SaleIgnored":
    state = SaleIgnored(reprocessSlot: true, returnBytes: true)
    discard await state.run(agent)
    check eventually returnBytesWas == true
    check eventually reprocessSlotWas == true
