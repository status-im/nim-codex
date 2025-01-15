import ./statemachine
import ./states/pending
import ./states/unknown
import ./purchaseid

# Purchase is implemented as a state machine.
#
# It can either be a new (pending) purchase that still needs to be submitted
# on-chain, or it is a purchase that was previously submitted on-chain, and
# we're just restoring its (unknown) state after a node restart.
#
#                                                                      |
#                                                                      v
#                                         ------------------------- unknown
#        |                               /                             /
#        v                              v                             /
#     pending ----> submitted ----> started ---------> finished <----/
#                        \              \                           /
#                         \              ------------> failed <----/
#                          \                                      /
#                           --> cancelled <-----------------------

export Purchase
export purchaseid
export statemachine

func new*(
    _: type Purchase, requestId: RequestId, market: Market, clock: Clock
): Purchase =
  ## create a new instance of a Purchase
  ##
  var purchase = Purchase.new()
  {.cast(noSideEffect).}:
    purchase.future = newFuture[void]()
  purchase.requestId = requestId
  purchase.market = market
  purchase.clock = clock

  return purchase

func new*(
    _: type Purchase, request: StorageRequest, market: Market, clock: Clock
): Purchase =
  ## Create a new purchase using the given market and clock
  let purchase = Purchase.new(request.id, market, clock)
  purchase.request = some request
  return purchase

proc start*(purchase: Purchase) =
  purchase.start(PurchasePending())

proc load*(purchase: Purchase) =
  purchase.start(PurchaseUnknown())

proc wait*(purchase: Purchase) {.async.} =
  await purchase.future

func id*(purchase: Purchase): PurchaseId =
  PurchaseId(purchase.requestId)

func finished*(purchase: Purchase): bool =
  purchase.future.finished

func error*(purchase: Purchase): ?(ref CatchableError) =
  if purchase.future.failed:
    some purchase.future.error
  else:
    none (ref CatchableError)

func state*(purchase: Purchase): ?string =
  proc description(state: State): string =
    $state

  purchase.query(description)
