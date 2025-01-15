import pkg/metrics

import ../../logutils
import ../statemachine
import ./errorhandling

declareCounter(codex_purchases_cancelled, "codex purchases cancelled")

logScope:
  topics = "marketplace purchases cancelled"

type PurchaseCancelled* = ref object of ErrorHandlingState

method `$`*(state: PurchaseCancelled): string =
  "cancelled"

method run*(state: PurchaseCancelled, machine: Machine): Future[?State] {.async.} =
  codex_purchases_cancelled.inc()
  let purchase = Purchase(machine)

  warn "Request cancelled, withdrawing remaining funds", requestId = purchase.requestId
  await purchase.market.withdrawFunds(purchase.requestId)

  let error = newException(Timeout, "Purchase cancelled due to timeout")
  purchase.future.fail(error)
