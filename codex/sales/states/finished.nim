import pkg/chronos

import ../../logutils
import ../statemachine
import ../salesagent
import ./errorhandling
import ./cancelled
import ./failed

logScope:
  topics = "marketplace sales finished"

type SaleFinished* = ref object of ErrorHandlingState

method `$`*(state: SaleFinished): string =
  "SaleFinished"

method onCancelled*(state: SaleFinished, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFinished, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(state: SaleFinished, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data

  without request =? data.request:
    raiseAssert "no sale request"

  info "Slot finished and paid out",
    requestId = data.requestId, slotIndex = data.slotIndex

  if onCleanUp =? agent.onCleanUp:
    await onCleanUp()
