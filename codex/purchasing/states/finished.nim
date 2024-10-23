import pkg/metrics

import ../statemachine
import ../../logutils

declareCounter(codex_purchases_finished, "codex purchases finished")

logScope:
  topics = "marketplace purchases finished"

type PurchaseFinished* = ref object of PurchaseState

method `$`*(state: PurchaseFinished): string =
  "finished"

method run*(state: PurchaseFinished, machine: Machine): Future[?State] {.async.} =
  codex_purchases_finished.inc()
  let purchase = Purchase(machine)
  info "Purchase finished, withdrawing remaining funds", requestId = purchase.requestId
  await purchase.market.withdrawFunds(purchase.requestId)

  purchase.future.complete()
