import pkg/metrics

import ../../logutils
import ../statemachine
import ./errorhandling
import ./finished
import ./failed

declareCounter(codex_purchases_started, "codex purchases started")

logScope:
  topics = "marketplace purchases started"

type PurchaseStarted* = ref object of ErrorHandlingState

method `$`*(state: PurchaseStarted): string =
  "started"

method run*(state: PurchaseStarted, machine: Machine): Future[?State] {.async.} =
  codex_purchases_started.inc()
  let purchase = Purchase(machine)

  let clock = purchase.clock
  let market = purchase.market
  info "All required slots filled, purchase started", requestId = purchase.requestId

  let failed = newFuture[void]()
  proc callback(_: RequestId) =
    failed.complete()

  let subscription = await market.subscribeRequestFailed(purchase.requestId, callback)

  # Ensure that we're past the request end by waiting an additional second
  let ended = clock.waitUntil((await market.getRequestEnd(purchase.requestId)) + 1)
  let fut = await one(ended, failed)
  await subscription.unsubscribe()
  if fut.id == failed.id:
    ended.cancelSoon()
    return some State(PurchaseFailed())
  else:
    failed.cancelSoon()
    return some State(PurchaseFinished())
