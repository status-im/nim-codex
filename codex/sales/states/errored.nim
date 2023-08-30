import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import pkg/chronicles
import ../statemachine
import ../salesagent
import ../../utils/exceptions

logScope:
    topics = "marketplace sales errored"

type SaleErrored* = ref object of SaleState
  error*: ref CatchableError

method `$`*(state: SaleErrored): string = "SaleErrored"

method onError*(state: SaleState, err: ref CatchableError): ?State {.upraises:[].} =
  error "error during SaleErrored run", error = err.msg

method run*(state: SaleErrored, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context

  error "Sale error", error=state.error.msgDetail, requestId = data.requestId, slotIndex = data.slotIndex

  if onClear =? context.onClear and
      request =? data.request and
      slotIndex =? data.slotIndex:
    onClear(request, slotIndex)

  if onCleanUp =? agent.onCleanUp:
    await onCleanUp()

