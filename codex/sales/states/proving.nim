import std/options
import pkg/questionable/results
import ../../clock
import ../../logutils
import ../../utils/exceptions
import ../statemachine
import ../salesagent
import ../salescontext
import ./errorhandling
import ./cancelled
import ./failed
import ./errored
import ./payout

logScope:
  topics = "marketplace sales proving"

type
  SlotNotFilledError* = object of CatchableError
  SaleProving* = ref object of ErrorHandlingState
    loop: Future[void]

method prove*(
  state: SaleProving,
  slot: Slot,
  challenge: ProofChallenge,
  onProve: OnProve,
  market: Market,
  currentPeriod: Period
) {.base, async.} =
  try:
    without proof =? (await onProve(slot, challenge)), err:
      error "Failed to generate proof", error = err.msg
      # In this state, there's nothing we can do except try again next time.
      return
    debug "Submitting proof", currentPeriod = currentPeriod, slotId = slot.id
    await market.submitProof(slot.id, proof)
  except CancelledError as error:
    trace "Submitting proof cancelled"
    raise error
  except CatchableError as e:
    error "Submitting proof failed", msg = e.msgDetail

proc proveLoop(
  state: SaleProving,
  market: Market,
  clock: Clock,
  request: StorageRequest,
  slotIndex: UInt256,
  onProve: OnProve
) {.async.} =

  let slot = Slot(request: request, slotIndex: slotIndex)
  let slotId = slot.id

  logScope:
    period = currentPeriod
    requestId = request.id
    slotIndex
    slotId = slot.id

  proc getCurrentPeriod(): Future[Period] {.async.} =
    let periodicity = await market.periodicity()
    return periodicity.periodOf(clock.now().u256)

  proc waitUntilPeriod(period: Period) {.async.} =
    let periodicity = await market.periodicity()
    # Ensure that we're past the period boundary by waiting an additional second
    await clock.waitUntil(periodicity.periodStart(period).truncate(int64) + 1)

  while true:
    let currentPeriod = await getCurrentPeriod()
    let slotState = await market.slotState(slot.id)

    case slotState
    of SlotState.Filled:
      debug "Proving for new period", period = currentPeriod
      if (await market.isProofRequired(slotId)) or (await market.willProofBeRequired(slotId)):
        let challenge = await market.getChallenge(slotId)
        debug "Proof is required", period = currentPeriod, challenge = challenge
        await state.prove(slot, challenge, onProve, market, currentPeriod)
    of SlotState.Cancelled:
      debug "Slot reached cancelled state"
      # do nothing, let onCancelled callback take care of it
    of SlotState.Failed:
      debug "Slot reached failed state"
      # do nothing, let onFailed callback take care of it
    of SlotState.Finished:
      debug "Slot reached finished state", period = currentPeriod
      return # exit the loop
    else:
      let message = "Slot is not in Filled state, but in state: " & $slotState
      raise newException(SlotNotFilledError, message)

    debug "waiting until next period"
    await waitUntilPeriod(currentPeriod + 1)

method `$`*(state: SaleProving): string = "SaleProving"

method onCancelled*(state: SaleProving, request: StorageRequest): ?State =
  # state.loop cancellation happens automatically when run is cancelled due to
  # state change
  return some State(SaleCancelled())

method onFailed*(state: SaleProving, request: StorageRequest): ?State =
  # state.loop cancellation happens automatically when run is cancelled due to
  # state change
  return some State(SaleFailed())

method run*(state: SaleProving, machine: Machine): Future[?State] {.async.} =
  let data = SalesAgent(machine).data
  let context = SalesAgent(machine).context

  without request =? data.request:
    raiseAssert "no sale request"

  without onProve =? context.onProve:
    raiseAssert "onProve callback not set"

  without market =? context.market:
    raiseAssert("market not set")

  without clock =? context.clock:
    raiseAssert("clock not set")

  debug "Start proving", requestId = data.requestId, slotIndex = data.slotIndex
  try:
    let loop = state.proveLoop(market, clock, request, data.slotIndex, onProve)
    state.loop = loop
    await loop
  except CancelledError:
    discard
  except CatchableError as e:
    error "Proving failed", msg = e.msg
    return some State(SaleErrored(error: e))
  finally:
    # Cleanup of the proving loop
    debug "Stopping proving.", requestId = data.requestId, slotIndex = data.slotIndex

    if not state.loop.isNil:
      if not state.loop.finished:
        try:
          await state.loop.cancelAndWait()
        except CatchableError as e:
          error "Error during cancellation of proving loop", msg = e.msg

      state.loop = nil

  return some State(SalePayout())
