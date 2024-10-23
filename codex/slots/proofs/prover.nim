## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##

import pkg/chronos
import pkg/chronicles
import pkg/circomcompat
import pkg/poseidon2
import pkg/questionable/results

import pkg/libp2p/cid

import ../../manifest
import ../../merkletree
import ../../stores
import ../../market
import ../../utils/poseidon2digest
import ../../conf

import ../builder
import ../sampler

import ./backends
import ./backendfactory
import ../types

export backends

logScope:
  topics = "codex prover"

type
  AnyProof* = CircomProof

  AnySampler* = Poseidon2Sampler
  AnyBuilder* = Poseidon2Builder

  AnyProofInputs* = ProofInputs[Poseidon2Hash]
  Prover* = ref object of RootObj
    backend: AnyBackend
    store: BlockStore
    nSamples: int

proc prove*(
  self: Prover,
  slotIdx: int,
  manifest: Manifest,
  challenge: ProofChallenge): Future[?!(AnyProofInputs, AnyProof)] {.async.} =
  ## Prove a statement using backend.
  ## Returns a future that resolves to a proof.

  logScope:
    cid = manifest.treeCid
    slot = slotIdx
    challenge = challenge

  trace "Received proof challenge"

  without builder =? AnyBuilder.new(self.store, manifest), err:
    error "Unable to create slots builder", err = err.msg
    return failure(err)

  without sampler =? AnySampler.new(slotIdx, self.store, builder), err:
    error "Unable to create data sampler", err = err.msg
    return failure(err)

  without proofInput =? await sampler.getProofInput(challenge, self.nSamples), err:
    error "Unable to get proof input for slot", err = err.msg
    return failure(err)

  # prove slot
  without proof =? self.backend.prove(proofInput), err:
    error "Unable to prove slot", err = err.msg
    return failure(err)

  success (proofInput, proof)

proc verify*(
  self: Prover,
  proof: AnyProof,
  inputs: AnyProofInputs): Future[?!bool] {.async.} =
  ## Prove a statement using backend.
  ## Returns a future that resolves to a proof.
  self.backend.verify(proof, inputs)

proc new*(
  _: type Prover,
  store: BlockStore,
  backend: AnyBackend,
  nSamples: int): Prover =

  Prover(
    store: store,
    backend: backend,
    nSamples: nSamples)
