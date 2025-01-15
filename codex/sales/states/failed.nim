import ../../logutils
import ../salesagent
import ../statemachine
import ./errorhandling
import ./errored

logScope:
  topics = "marketplace sales failed"

type
  SaleFailed* = ref object of ErrorHandlingState
  SaleFailedError* = object of SaleError

method `$`*(state: SaleFailed): string =
  "SaleFailed"

method run*(state: SaleFailed, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let market = SalesAgent(machine).context.market

  without request =? data.request:
    raiseAssert "no sale request"

  let slot = Slot(request: request, slotIndex: data.slotIndex)
  debug "Removing slot from mySlots",
    requestId = data.requestId, slotIndex = data.slotIndex
  await market.freeSlot(slot.id)

  let error = newException(SaleFailedError, "Sale failed")
  return some State(SaleErrored(error: error))
