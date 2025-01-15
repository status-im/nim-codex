import ../../logutils
import ../statemachine
import ../salesagent
import ./filled
import ./finished
import ./failed
import ./errored
import ./proving
import ./cancelled
import ./payout

logScope:
  topics = "marketplace sales unknown"

type
  SaleUnknown* = ref object of SaleState
  SaleUnknownError* = object of CatchableError
  UnexpectedSlotError* = object of SaleUnknownError

method `$`*(state: SaleUnknown): string =
  "SaleUnknown"

method onCancelled*(state: SaleUnknown, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleUnknown, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(state: SaleUnknown, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let market = agent.context.market

  await agent.retrieveRequest()
  await agent.subscribe()

  let slotId = slotId(data.requestId, data.slotIndex)
  let slotState = await market.slotState(slotId)

  case slotState
  of SlotState.Free:
    let error =
      newException(UnexpectedSlotError, "Slot state on chain should not be 'free'")
    return some State(SaleErrored(error: error))
  of SlotState.Filled:
    return some State(SaleFilled())
  of SlotState.Finished:
    return some State(SalePayout())
  of SlotState.Paid:
    return some State(SaleFinished())
  of SlotState.Failed:
    return some State(SaleFailed())
  of SlotState.Cancelled:
    return some State(SaleCancelled())
  of SlotState.Repair:
    let error = newException(
      SlotFreedError, "Slot was forcible freed and host was removed from its hosting"
    )
    return some State(SaleErrored(error: error))
