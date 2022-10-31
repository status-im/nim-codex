import ../utils/statemachine
import ../market
import ../clock
import ../errors

export market
export clock
export statemachine

type
  Purchase* = ref object of StateMachine
    future*: Future[void]
    market*: Market
    clock*: Clock
    request*: StorageRequest
  PurchaseState* = ref object of AsyncState
  PurchaseError* = object of CodexError
