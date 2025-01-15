import pkg/questionable
import pkg/upraises
import ../errors
import ../utils/asyncstatemachine
import ../market
import ../clock
import ../contracts/requests

export market
export clock
export asyncstatemachine

type
  SaleState* = ref object of State
  SaleError* = ref object of CodexError

method onCancelled*(
    state: SaleState, request: StorageRequest
): ?State {.base, upraises: [].} =
  discard

method onFailed*(
    state: SaleState, request: StorageRequest
): ?State {.base, upraises: [].} =
  discard

method onSlotFilled*(
    state: SaleState, requestId: RequestId, slotIndex: UInt256
): ?State {.base, upraises: [].} =
  discard

proc cancelledEvent*(request: StorageRequest): Event =
  return proc(state: State): ?State =
    SaleState(state).onCancelled(request)

proc failedEvent*(request: StorageRequest): Event =
  return proc(state: State): ?State =
    SaleState(state).onFailed(request)

proc slotFilledEvent*(requestId: RequestId, slotIndex: UInt256): Event =
  return proc(state: State): ?State =
    SaleState(state).onSlotFilled(requestId, slotIndex)
