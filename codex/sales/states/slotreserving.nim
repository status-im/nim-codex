import pkg/questionable
import pkg/questionable/results
import pkg/metrics

import ../../logutils
import ../../market
import ../salesagent
import ../statemachine
import ./errorhandling
import ./cancelled
import ./failed
import ./filled
import ./ignored
import ./downloading
import ./errored

type
  SaleSlotReserving* = ref object of ErrorHandlingState

logScope:
  topics = "marketplace sales reserving"

method `$`*(state: SaleSlotReserving): string = "SaleSlotReserving"

method onCancelled*(state: SaleSlotReserving, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleSlotReserving, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(state: SaleSlotReserving, requestId: RequestId,
                     slotIndex: UInt256): ?State =
  return some State(SaleFilled())

method run*(state: SaleSlotReserving, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context
  let market = context.market

  logScope:
    requestId = data.requestId
    slotIndex = data.slotIndex

  let canReserve = await market.canReserveSlot(data.requestId, data.slotIndex)
  if canReserve:
    try:
      trace "Reserving slot"
      await market.reserveSlot(data.requestId, data.slotIndex)
    except MarketError as e:
      return some State( SaleErrored(error: e) )

    trace "Slot successfully reserved"
    return some State( SaleDownloading() )

  else:
    # do not re-add this slot to the queue, and return bytes from Reservation to
    # the Availability
    debug "Slot cannot be reserved, ignoring"
    return some State( SaleIgnored(reprocessSlot: false, returnBytes: true) )

