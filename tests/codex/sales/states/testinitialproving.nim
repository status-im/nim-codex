import pkg/questionable
import pkg/chronos
import pkg/codex/contracts/requests
import pkg/codex/sales/states/initialproving
import pkg/codex/sales/states/cancelled
import pkg/codex/sales/states/failed
import pkg/codex/sales/states/filling
import pkg/codex/sales/states/errored
import pkg/codex/sales/salesagent
import pkg/codex/sales/salescontext
import pkg/codex/market

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../helpers/mockclock
import ../helpers/periods

asyncchecksuite "sales state 'initialproving'":
  let proof = Groth16Proof.example
  let request = StorageRequest.example
  let slotIndex = (request.ask.slots div 2).u256
  let market = MockMarket.new()
  let clock = MockClock.new()

  var state: SaleInitialProving
  var agent: SalesAgent
  var receivedChallenge: ProofChallenge

  setup:
    let onProve = proc(
        slot: Slot, challenge: ProofChallenge
    ): Future[?!Groth16Proof] {.async.} =
      receivedChallenge = challenge
      return success(proof)
    let context = SalesContext(onProve: onProve.some, market: market, clock: clock)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    state = SaleInitialProving.new()

  proc allowProofToStart() {.async.} =
    # it won't start proving until the next period
    await clock.advanceToNextPeriod(market)

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "waits for the beginning of the period to get the challenge":
    let future = state.run(agent)
    check eventually clock.isWaiting
    check not future.finished
    await allowProofToStart()
    discard await future

  test "waits another period when the proof pointer is about to wrap around":
    market.proofPointer = 250
    let future = state.run(agent)
    await allowProofToStart()
    check eventually clock.isWaiting
    check not future.finished
    market.proofPointer = 100
    await allowProofToStart()
    discard await future

  test "onProve callback provides proof challenge":
    market.proofChallenge = ProofChallenge.example

    let future = state.run(agent)
    await allowProofToStart()

    discard await future

    check receivedChallenge == market.proofChallenge

  test "switches to filling state when initial proving is complete":
    let future = state.run(agent)
    await allowProofToStart()
    let next = await future

    check !next of SaleFilling
    check SaleFilling(!next).proof == proof

  test "switches to errored state when onProve callback fails":
    let onProveFailed: OnProve = proc(
        slot: Slot, challenge: ProofChallenge
    ): Future[?!Groth16Proof] {.async.} =
      return failure("oh no!")

    let proofFailedContext =
      SalesContext(onProve: onProveFailed.some, market: market, clock: clock)
    agent = newSalesAgent(proofFailedContext, request.id, slotIndex, request.some)

    let future = state.run(agent)
    await allowProofToStart()
    let next = await future

    check !next of SaleErrored
