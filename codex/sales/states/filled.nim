import pkg/questionable
import pkg/chronicles
import ../statemachine
import ../salesagent
import ./errorhandling
import ./errored
import ./cancelled
import ./failed
import ./proving

type
  SaleFilled* = ref object of ErrorHandlingState
  HostMismatchError* = object of CatchableError

method onCancelled*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleFailed())

method `$`*(state: SaleFilled): string = "SaleFilled"

method run*(state: SaleFilled, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let market = SalesAgent(machine).context.market

  without slotIndex =? data.slotIndex:
    raiseAssert("no slot index assigned")

  let host = await market.getHost(data.requestId, slotIndex)
  let me = await market.getSigner()
  if host == me.some:
    info "Slot succesfully filled", requestId = $data.requestId, slotIndex
    return some State(SaleProving())
  else:
    let error = newException(HostMismatchError, "Slot filled by other host")
    return some State(SaleErrored(error: error))
