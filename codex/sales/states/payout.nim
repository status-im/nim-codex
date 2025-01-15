import ../../logutils
import ../../market
import ../statemachine
import ../salesagent
import ./errorhandling
import ./cancelled
import ./failed
import ./finished

logScope:
  topics = "marketplace sales payout"

type SalePayout* = ref object of ErrorHandlingState

method `$`*(state: SalePayout): string =
  "SalePayout"

method onCancelled*(state: SalePayout, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SalePayout, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run(state: SalePayout, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let market = SalesAgent(machine).context.market

  without request =? data.request:
    raiseAssert "no sale request"

  let slot = Slot(request: request, slotIndex: data.slotIndex)
  debug "Collecting finished slot's reward",
    requestId = data.requestId, slotIndex = data.slotIndex
  await market.freeSlot(slot.id)

  return some State(SaleFinished())
