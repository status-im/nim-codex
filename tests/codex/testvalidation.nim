import pkg/chronos
import std/strformat
import std/random

import codex/validation
import codex/periods

import ../asynctest
import ./helpers/mockmarket
import ./helpers/mockclock
import ./examples
import ./helpers

asyncchecksuite "validation":
  let period = 10
  let timeout = 5
  let maxSlots = MaxSlots(100)
  let validationGroups = ValidationGroups(8).some
  let slot = Slot.example
  let proof = Groth16Proof.example
  let collateral = slot.request.ask.collateral

  var validation: Validation
  var market: MockMarket
  var clock: MockClock
  var groupIndex: uint16

  proc initValidationConfig(maxSlots: MaxSlots,
                            validationGroups: ?ValidationGroups,
                            groupIndex: uint16 = 0): ValidationConfig =
    without validationConfig =? ValidationConfig.init(
      maxSlots, groups=validationGroups, groupIndex), error:
      raiseAssert fmt"Creating ValidationConfig failed! Error msg: {error.msg}"
    validationConfig

  setup:
    groupIndex = groupIndexForSlotId(slot.id, !validationGroups)
    market = MockMarket.new()
    clock = MockClock.new()
    let validationConfig = initValidationConfig(
        maxSlots, validationGroups, groupIndex)
    validation = Validation.new(clock, market, validationConfig)
    market.config.proofs.period = period.u256
    market.config.proofs.timeout = timeout.u256
    await validation.start()

  teardown:
    await validation.stop()

  proc advanceToNextPeriod =
    let periodicity = Periodicity(seconds: period.u256)
    let period = periodicity.periodOf(clock.now().u256)
    let periodEnd = periodicity.periodEnd(period)
    clock.set((periodEnd + 1).truncate(int))

  test "the list of slots that it's monitoring is empty initially":
    check validation.slots.len == 0

  for (validationGroups, groupIndex) in [(100, 100'u16), (100, 101'u16)]:
    test "initializing ValidationConfig fails when groupIndex is " &
        "greater than or equal to validationGroups " &
        fmt"(testing for {groupIndex = }, {validationGroups = })":
      let groups = ValidationGroups(validationGroups).some
      let validationConfig = ValidationConfig.init(
          maxSlots, groups = groups, groupIndex = groupIndex)
      check validationConfig.isFailure == true
      check validationConfig.error.msg == "The value of the group index " &
          "must be less than validation groups! " &
          fmt"(got: {groupIndex = }, groups = {!groups})"
  
  test "initializing ValidationConfig fails when maxSlots is negative":
    let maxSlots = -1
    let validationConfig = ValidationConfig.init(
        maxSlots = maxSlots, groups = ValidationGroups.none)
    check validationConfig.isFailure == true
    check validationConfig.error.msg == "The value of maxSlots must " &
        fmt"be greater than or equal to 0! (got: {maxSlots})"
  
  test "initializing ValidationConfig fails when maxSlots is negative " &
      "(validationGroups set)":
    let maxSlots = -1
    let validationConfig = ValidationConfig.init(
        maxSlots = maxSlots, groups = validationGroups, groupIndex)
    check validationConfig.isFailure == true
    check validationConfig.error.msg == "The value of maxSlots must " &
        fmt"be greater than or equal to 0! (got: {maxSlots})"

  test "slot is not observed if it is not in the validation group":
    let validationConfig = initValidationConfig(maxSlots, validationGroups,
        (groupIndex + 1) mod uint16(!validationGroups))
    let validation = Validation.new(clock, market, validationConfig)
    await validation.start()
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots.len == 0

  test "when a slot is filled on chain, it is added to the list":
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    check validation.slots == @[slot.id]
  
  test "slot should be observed if maxSlots is set to 0":
    let validationConfig = initValidationConfig(
        maxSlots = 0, ValidationGroups.none)
    let validation = Validation.new(clock, market, validationConfig)
    await validation.start()
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots == @[slot.id]

  test "slot should be observed if validation group is not set (and " &
      "maxSlots is not 0)":
    let validationConfig = initValidationConfig(
        maxSlots, ValidationGroups.none)
    let validation = Validation.new(clock, market, validationConfig)
    await validation.start()
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots == @[slot.id]

  for state in [SlotState.Finished, SlotState.Failed]:
    test fmt"when slot state changes to {state}, it is removed from the list":
      await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
      market.slotState[slot.id] = state
      advanceToNextPeriod()
      check eventually validation.slots.len == 0

  test "when a proof is missed, it is marked as missing":
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    market.setCanProofBeMarkedAsMissing(slot.id, true)
    advanceToNextPeriod()
    await sleepAsync(1.millis)
    check market.markedAsMissingProofs.contains(slot.id)

  test "when a proof can not be marked as missing, it will not be marked":
    await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    market.setCanProofBeMarkedAsMissing(slot.id, false)
    advanceToNextPeriod()
    await sleepAsync(1.millis)
    check market.markedAsMissingProofs.len == 0

  test "it does not monitor more than the maximum number of slots":
    let validationGroups = ValidationGroups.none
    let validationConfig = initValidationConfig(
        maxSlots, validationGroups)
    let validation = Validation.new(clock, market, validationConfig)
    await validation.start()
    for _ in 0..<maxSlots + 1:
      let slot = Slot.example
      await market.fillSlot(slot.request.id, slot.slotIndex, proof, collateral)
    await validation.stop()
    check validation.slots.len == maxSlots
