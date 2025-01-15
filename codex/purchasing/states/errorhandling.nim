import pkg/questionable
import ../statemachine
import ./error

type ErrorHandlingState* = ref object of PurchaseState

method onError*(state: ErrorHandlingState, error: ref CatchableError): ?State =
  some State(PurchaseErrored(error: error))
