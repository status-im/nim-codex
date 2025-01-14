import std/sets
import std/sequtils
import pkg/chronos
import pkg/questionable/results

import ./validationconfig
import ./market
import ./clock
import ./logutils

export market
export sets
export validationconfig

type
  Validation* = ref object
    slots: HashSet[SlotId]
    clock: Clock
    market: Market
    subscriptions: seq[Subscription]
    running: Future[void]
    periodicity: Periodicity
    proofTimeout: UInt256
    config: ValidationConfig

logScope:
  topics = "codex validator"

proc new*(
  _: type Validation,
  clock: Clock,
  market: Market,
  config: ValidationConfig
): Validation =
  Validation(clock: clock, market: market, config: config)

proc slots*(validation: Validation): seq[SlotId] =
  validation.slots.toSeq

proc getCurrentPeriod(validation: Validation): UInt256 =
  return validation.periodicity.periodOf(validation.clock.now().u256)

proc waitUntilNextPeriod(validation: Validation) {.async.} =
  let period = validation.getCurrentPeriod()
  let periodEnd = validation.periodicity.periodEnd(period)
  trace "Waiting until next period", currentPeriod = period
  await validation.clock.waitUntil(periodEnd.truncate(int64) + 1)

func groupIndexForSlotId*(slotId: SlotId,
                          validationGroups: ValidationGroups): uint16 =
  let slotIdUInt256 = UInt256.fromBytesBE(slotId.toArray)
  (slotIdUInt256 mod validationGroups.u256).truncate(uint16)

func maxSlotsConstraintRespected(validation: Validation): bool =
  validation.config.maxSlots == 0 or
    validation.slots.len < validation.config.maxSlots

func shouldValidateSlot(validation: Validation, slotId: SlotId): bool =
  without validationGroups =? validation.config.groups:
    return true
  groupIndexForSlotId(slotId, validationGroups) ==
    validation.config.groupIndex

proc subscribeSlotFilled(validation: Validation) {.async.} =
  proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
    if not validation.maxSlotsConstraintRespected:
      return
    let slotId = slotId(requestId, slotIndex)
    if validation.shouldValidateSlot(slotId):
      trace "Adding slot", slotId
      validation.slots.incl(slotId)
  let subscription = await validation.market.subscribeSlotFilled(onSlotFilled)
  validation.subscriptions.add(subscription)

proc removeSlotsThatHaveEnded(validation: Validation) {.async.} =
  var ended: HashSet[SlotId]
  let slots = validation.slots
  for slotId in slots:
    let state = await validation.market.slotState(slotId)
    if state != SlotState.Filled:
      trace "Removing slot", slotId, slotState = state
      ended.incl(slotId)
  validation.slots.excl(ended)

proc markProofAsMissing(validation: Validation,
                        slotId: SlotId,
                        period: Period) {.async.} =
  logScope:
    currentPeriod = validation.getCurrentPeriod()

  try:
    if await validation.market.canProofBeMarkedAsMissing(slotId, period):
      trace "Marking proof as missing", slotId, periodProofMissed = period
      await validation.market.markProofAsMissing(slotId, period)
    else:
      let inDowntime {.used.} = await validation.market.inDowntime(slotId)
      trace "Proof not missing", checkedPeriod = period, inDowntime
  except CancelledError:
    raise
  except CatchableError as e:
    error "Marking proof as missing failed", msg = e.msg

proc markProofsAsMissing(validation: Validation) {.async.} =
  let slots = validation.slots
  for slotId in slots:
    let previousPeriod = validation.getCurrentPeriod() - 1
    await validation.markProofAsMissing(slotId, previousPeriod)

proc run(validation: Validation) {.async: (raises: []).} =
  trace "Validation started"
  try:
    while true:
      await validation.waitUntilNextPeriod()
      await validation.removeSlotsThatHaveEnded()
      await validation.markProofsAsMissing()
  except CancelledError:
    trace "Validation stopped"
    discard # do not propagate as run is asyncSpawned
  except CatchableError as e:
    error "Validation failed", msg = e.msg

proc epochForDurationBackFromNow(validation: Validation,
    duration: Duration): SecondsSince1970 =
  return validation.clock.now - duration.secs

proc restoreHistoricalState(validation: Validation) {.async.} =
  trace "Restoring historical state..."
  let requestDurationLimit = await validation.market.requestDurationLimit
  let startTimeEpoch = validation.epochForDurationBackFromNow(requestDurationLimit)
  let slotFilledEvents = await validation.market.queryPastSlotFilledEvents(
    fromTime = startTimeEpoch)
  for event in slotFilledEvents:
    if not validation.maxSlotsConstraintRespected:
      break
    let slotId = slotId(event.requestId, event.slotIndex)
    let slotState = await validation.market.slotState(slotId)
    if slotState == SlotState.Filled and validation.shouldValidateSlot(slotId):
      trace "Adding slot [historical]", slotId
      validation.slots.incl(slotId)
  trace "Historical state restored", numberOfSlots = validation.slots.len

proc start*(validation: Validation) {.async.} =
  trace "Starting validator", groups = validation.config.groups,
    groupIndex = validation.config.groupIndex
  validation.periodicity = await validation.market.periodicity()
  validation.proofTimeout = await validation.market.proofTimeout()
  await validation.subscribeSlotFilled()
  await validation.restoreHistoricalState()
  validation.running = validation.run()
  asyncSpawn validation.running

proc stop*(validation: Validation) {.async.} =
  if not validation.running.isNil and not validation.running.finished:
    await validation.running.cancelAndWait()
  while validation.subscriptions.len > 0:
    let subscription = validation.subscriptions.pop()
    await subscription.unsubscribe()
