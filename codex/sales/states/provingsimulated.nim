import ../../conf
when codex_enable_proof_failures:
  import std/strutils
  import pkg/stint
  import pkg/ethers

  import ../../contracts/requests
  import ../../logutils
  import ../../market
  import ../../utils/exceptions
  import ../salescontext
  import ./proving

  logScope:
    topics = "marketplace sales simulated-proving"

  type SaleProvingSimulated* = ref object of SaleProving
    failEveryNProofs*: int
    proofCount: int

  proc onSubmitProofError(error: ref CatchableError, period: UInt256, slotId: SlotId) =
    error "Submitting invalid proof failed", period, slotId, msg = error.msgDetail

  method prove*(
      state: SaleProvingSimulated,
      slot: Slot,
      challenge: ProofChallenge,
      onProve: OnProve,
      market: Market,
      currentPeriod: Period,
  ) {.async.} =
    trace "Processing proving in simulated mode"
    state.proofCount += 1
    if state.failEveryNProofs > 0 and state.proofCount mod state.failEveryNProofs == 0:
      state.proofCount = 0

      try:
        warn "Submitting INVALID proof", period = currentPeriod, slotId = slot.id
        await market.submitProof(slot.id, Groth16Proof.default)
      except MarketError as e:
        if not e.msg.contains("Invalid proof"):
          onSubmitProofError(e, currentPeriod, slot.id)
      except CancelledError as error:
        raise error
      except CatchableError as e:
        onSubmitProofError(e, currentPeriod, slot.id)
    else:
      await procCall SaleProving(state).prove(
        slot, challenge, onProve, market, currentPeriod
      )
