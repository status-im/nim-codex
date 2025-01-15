import pkg/chronos

import ../../logutils
import ../statemachine
import ../salesagent
import ./errorhandling

logScope:
  topics = "marketplace sales ignored"

# Ignored slots could mean there was no availability or that the slot could
# not be reserved.

type SaleIgnored* = ref object of ErrorHandlingState
  reprocessSlot*: bool # readd slot to queue with `seen` flag
  returnBytes*: bool # return unreleased bytes from Reservation to Availability

method `$`*(state: SaleIgnored): string =
  "SaleIgnored"

method run*(state: SaleIgnored, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)

  if onCleanUp =? agent.onCleanUp:
    await onCleanUp(
      reprocessSlot = state.reprocessSlot, returnBytes = state.returnBytes
    )
