import std/unittest
import pkg/questionable
import pkg/codex/contracts/requests
import pkg/codex/sales/states/finished
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/failed
import ../../examples
import ../../helpers

checksuite "sales state 'finished'":
  let request = StorageRequest.example
  var state: SaleFinished

  setup:
    state = SaleFinished.new()

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed
