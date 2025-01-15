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
import ./slotreserving
import ./errored

declareCounter(
  codex_reservations_availability_mismatch, "codex reservations availability_mismatch"
)

type SalePreparing* = ref object of ErrorHandlingState

logScope:
  topics = "marketplace sales preparing"

method `$`*(state: SalePreparing): string =
  "SalePreparing"

method onCancelled*(state: SalePreparing, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SalePreparing, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(
    state: SalePreparing, requestId: RequestId, slotIndex: UInt256
): ?State =
  return some State(SaleFilled())

method run*(state: SalePreparing, machine: Machine): Future[?State] {.async.} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context
  let market = context.market
  let reservations = context.reservations

  await agent.retrieveRequest()
  await agent.subscribe()

  without request =? data.request:
    raiseAssert "no sale request"

  let slotId = slotId(data.requestId, data.slotIndex)
  let state = await market.slotState(slotId)
  if state != SlotState.Free and state != SlotState.Repair:
    return some State(SaleIgnored(reprocessSlot: false, returnBytes: false))

  # TODO: Once implemented, check to ensure the host is allowed to fill the slot,
  # due to the [sliding window mechanism](https://github.com/codex-storage/codex-research/blob/master/design/marketplace.md#dispersal)

  logScope:
    slotIndex = data.slotIndex
    slotSize = request.ask.slotSize
    duration = request.ask.duration
    pricePerSlot = request.ask.pricePerSlot

  # availability was checked for this slot when it entered the queue, however
  # check to the ensure that there is still availability as they may have
  # changed since being added (other slots may have been processed in that time)
  without availability =?
    await reservations.findAvailability(
      request.ask.slotSize, request.ask.duration, request.ask.pricePerSlot,
      request.ask.collateral,
    ):
    debug "No availability found for request, ignoring"

    return some State(SaleIgnored(reprocessSlot: true))

  info "Availability found for request, creating reservation"

  without reservation =?
    await reservations.createReservation(
      availability.id, request.ask.slotSize, request.id, data.slotIndex
    ), error:
    trace "Creation of reservation failed"
    # Race condition:
    # reservations.findAvailability (line 64) is no guarantee. You can never know for certain that the reservation can be created until after you have it.
    # Should createReservation fail because there's no space, we proceed to SaleIgnored.
    if error of BytesOutOfBoundsError:
      # Lets monitor how often this happen and if it is often we can make it more inteligent to handle it
      codex_reservations_availability_mismatch.inc()
      return some State(SaleIgnored(reprocessSlot: true))

    return some State(SaleErrored(error: error))

  trace "Reservation created succesfully"

  data.reservation = some reservation
  return some State(SaleSlotReserving())
