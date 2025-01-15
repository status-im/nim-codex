import pkg/metrics
import ../statemachine
import ../../utils/exceptions
import ../../logutils

declareCounter(codex_purchases_error, "codex purchases error")

logScope:
  topics = "marketplace purchases errored"

type PurchaseErrored* = ref object of PurchaseState
  error*: ref CatchableError

method `$`*(state: PurchaseErrored): string =
  "errored"

method run*(state: PurchaseErrored, machine: Machine): Future[?State] {.async.} =
  codex_purchases_error.inc()
  let purchase = Purchase(machine)

  error "Purchasing error",
    error = state.error.msgDetail, requestId = purchase.requestId

  purchase.future.fail(state.error)
