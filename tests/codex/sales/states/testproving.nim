import pkg/chronos
import pkg/questionable
import pkg/codex/contracts/requests
import pkg/codex/sales/states/proving
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/failed
import pkg/codex/sales/states/payout
import pkg/codex/sales/states/errored
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../helpers/mockclock

asyncchecksuite "sales state 'proving'":
  let slot = Slot.example
  let request = slot.request
  let proof = Groth16Proof.example

  var market: MockMarket
  var clock: MockClock
  var agent: SalesAgent
  var state: SaleProving
  var receivedChallenge: ProofChallenge

  setup:
    clock = MockClock.new()
    market = MockMarket.new()
    let onProve = proc(
        slot: Slot, challenge: ProofChallenge
    ): Future[?!Groth16Proof] {.async.} =
      receivedChallenge = challenge
      return success(proof)
    let context = SalesContext(market: market, clock: clock, onProve: onProve.some)
    agent = newSalesAgent(context, request.id, slot.slotIndex, request.some)
    state = SaleProving.new()

  proc advanceToNextPeriod(market: Market) {.async.} =
    let periodicity = await market.periodicity()
    let current = periodicity.periodOf(clock.now().u256)
    let periodEnd = periodicity.periodEnd(current)
    clock.set(periodEnd.truncate(int64) + 1)

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "submits proofs":
    var receivedIds: seq[SlotId]

    proc onProofSubmission(id: SlotId) =
      receivedIds.add(id)

    let subscription = await market.subscribeProofSubmission(onProofSubmission)
    market.slotState[slot.id] = SlotState.Filled

    let future = state.run(agent)

    market.setProofRequired(slot.id, true)
    await market.advanceToNextPeriod()

    check eventually receivedIds.contains(slot.id)

    await future.cancelAndWait()
    await subscription.unsubscribe()

  test "switches to payout state when request is finished":
    market.slotState[slot.id] = SlotState.Filled

    let future = state.run(agent)

    market.slotState[slot.id] = SlotState.Finished
    await market.advanceToNextPeriod()

    check eventually future.finished
    check !(future.read()) of SalePayout

  test "switches to error state when slot is no longer filled":
    market.slotState[slot.id] = SlotState.Filled

    let future = state.run(agent)

    market.slotState[slot.id] = SlotState.Free
    await market.advanceToNextPeriod()

    check eventually future.finished
    check !(future.read()) of SaleErrored

  test "onProve callback provides proof challenge":
    market.proofChallenge = ProofChallenge.example
    market.slotState[slot.id] = SlotState.Filled
    market.setProofRequired(slot.id, true)

    let future = state.run(agent)

    check eventually receivedChallenge == market.proofChallenge

    await future.cancelAndWait()
