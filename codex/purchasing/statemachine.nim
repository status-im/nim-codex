import ../utils/asyncstatemachine
import ../market
import ../clock
import ../errors

export market
export clock
export asyncstatemachine

type
  Purchase* = ref object of Machine
    future*: Future[void]
    market*: Market
    clock*: Clock
    requestId*: RequestId
    request*: ?StorageRequest

  PurchaseState* = ref object of State
  PurchaseError* = object of CodexError
