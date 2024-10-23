import std/unittest
import pkg/questionable
import pkg/codex/contracts/requests
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/downloading
import pkg/codex/sales/states/errored
import pkg/codex/sales/states/failed
import pkg/codex/sales/states/filled
import ../../examples
import ../../helpers

checksuite "sales state 'downloading'":
  let request = StorageRequest.example
  let slotIndex = (request.ask.slots div 2).u256
  var state: SaleDownloading

  setup:
    state = SaleDownloading.new()

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "switches to filled state when slot is filled":
    let next = state.onSlotFilled(request.id, slotIndex)
    check !next of SaleFilled
