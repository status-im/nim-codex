import ../../logutils
import ../salesagent
import ../statemachine
import ./errorhandling

logScope:
  topics = "marketplace sales cancelled"

type
  SaleCancelled* = ref object of ErrorHandlingState

method `$`*(state: SaleCancelled): string = "SaleCancelled"

method run*(state: SaleCancelled, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let market = agent.context.market

  without request =? data.request:
    raiseAssert "no sale request"

  let slot = Slot(request: request, slotIndex: data.slotIndex)
  debug "Collecting collateral and partial payout",  requestId = data.requestId, slotIndex = data.slotIndex
  await market.freeSlot(slot.id)

  if onClear =? agent.context.onClear and
      request =? data.request:
    onClear(request, data.slotIndex)

  if onCleanUp =? agent.onCleanUp:
    await onCleanUp(returnBytes = true, reprocessSlot = false)

  warn "Sale cancelled due to timeout",  requestId = data.requestId, slotIndex = data.slotIndex
