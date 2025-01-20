import pkg/questionable
import pkg/chronos
import pkg/codex/contracts/requests
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/market

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../helpers/mockclock

asyncchecksuite "sales state 'cancelled'":
  let request = StorageRequest.example
  let slotIndex = (request.ask.slots div 2).u256
  let market = MockMarket.new()
  let clock = MockClock.new()

  var state: SaleCancelled
  var agent: SalesAgent
  var returnBytesWas = false
  var reprocessSlotWas = false

  setup:
    let onCleanUp =
      proc (
        returnBytes = false,
        reprocessSlot = false,
        currentCollateral = UInt256.none
      ) {.async.} =
        returnBytesWas = returnBytes
        reprocessSlotWas = reprocessSlot

    let context = SalesContext(
      market: market,
      clock: clock
    )
    agent = newSalesAgent(context,
                          request.id,
                          slotIndex,
                          request.some)
    agent.onCleanUp = onCleanUp
    state = SaleCancelled.new()

  test "calls onCleanUp with returnBytes = false and reprocessSlot = true":
    discard await state.run(agent)
    check eventually returnBytesWas == true
    check eventually reprocessSlotWas == false
