## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sugar

import pkg/chronos
import pkg/questionable/results
import pkg/circomcompat

import ../../types
import ../../../stores
import ../../../contracts

import ./converters

export circomcompat, converters

type
  CircomCompat* = object
    slotDepth     : int     # max depth of the slot tree
    datasetDepth  : int     # max depth of dataset  tree
    blkDepth      : int     # depth of the block merkle tree (pow2 for now)
    cellElms      : int     # number of field elements per cell
    numSamples    : int     # number of samples per slot
    r1csPath      : string  # path to the r1cs file
    wasmPath      : string  # path to the wasm file
    zkeyPath      : string  # path to the zkey file
    backendCfg    : ptr CircomBn254Cfg
    vkp*          : ptr CircomKey

  NormalizedProofInputs*[H] {.borrow: `.`.} = distinct ProofInputs[H]

func normalizeInput*[H](self: CircomCompat, input: ProofInputs[H]):
    NormalizedProofInputs[H] =
  ## Parameters in CIRCOM circuits are statically sized and must be properly
  ## padded before they can be passed onto the circuit. This function takes
  ## variable length parameters and performs that padding.
  ##
  ## The output from this function can be JSON-serialized and used as direct
  ## inputs to the CIRCOM circuit for testing and debugging when one wishes
  ## to bypass the Rust FFI.

  let normSamples = collect:
    for sample in input.samples:
      var merklePaths = sample.merklePaths
      merklePaths.setLen(self.slotDepth)
      Sample[H](
        cellData: sample.cellData,
        merklePaths: merklePaths
      )

  var normSlotProof = input.slotProof
  normSlotProof.setLen(self.datasetDepth)

  NormalizedProofInputs[H] ProofInputs[H](
    entropy: input.entropy,
    datasetRoot: input.datasetRoot,
    slotIndex: input.slotIndex,
    slotRoot: input.slotRoot,
    nCellsPerSlot: input.nCellsPerSlot,
    nSlotsPerDataSet: input.nSlotsPerDataSet,
    slotProof: normSlotProof,
    samples: normSamples
  )

proc release*(self: CircomCompat) =
  ## Release the ctx
  ##

  if not isNil(self.backendCfg):
    self.backendCfg.unsafeAddr.releaseCfg()

  if not isNil(self.vkp):
    self.vkp.unsafeAddr.release_key()

proc prove[H](
  self: CircomCompat,
  input: NormalizedProofInputs[H]): ?!CircomProof =

  doAssert input.samples.len == self.numSamples,
    "Number of samples does not match"

  doAssert input.slotProof.len <= self.datasetDepth,
    "Slot proof is too deep - dataset has more slots than what we can handle?"

  doAssert input.samples.allIt(
    block:
      (it.merklePaths.len <= self.slotDepth + self.blkDepth and
      it.cellData.len == self.cellElms)), "Merkle paths too deep or cells too big for circuit"

  # TODO: All parameters should match circom's static parametter
  var
    ctx: ptr CircomCompatCtx

  defer:
    if ctx != nil:
      ctx.addr.releaseCircomCompat()

  if initCircomCompat(
    self.backendCfg,
    addr ctx) != ERR_OK or ctx == nil:
    raiseAssert("failed to initialize CircomCompat ctx")

  var
    entropy = input.entropy.toBytes
    dataSetRoot = input.datasetRoot.toBytes
    slotRoot = input.slotRoot.toBytes

  if ctx.pushInputU256Array(
    "entropy".cstring, entropy[0].addr, entropy.len.uint32) != ERR_OK:
    return failure("Failed to push entropy")

  if ctx.pushInputU256Array(
    "dataSetRoot".cstring, dataSetRoot[0].addr, dataSetRoot.len.uint32) != ERR_OK:
    return failure("Failed to push data set root")

  if ctx.pushInputU256Array(
    "slotRoot".cstring, slotRoot[0].addr, slotRoot.len.uint32) != ERR_OK:
    return failure("Failed to push data set root")

  if ctx.pushInputU32(
    "nCellsPerSlot".cstring, input.nCellsPerSlot.uint32) != ERR_OK:
    return failure("Failed to push nCellsPerSlot")

  if ctx.pushInputU32(
    "nSlotsPerDataSet".cstring, input.nSlotsPerDataSet.uint32) != ERR_OK:
    return failure("Failed to push nSlotsPerDataSet")

  if ctx.pushInputU32(
    "slotIndex".cstring, input.slotIndex.uint32) != ERR_OK:
    return failure("Failed to push slotIndex")

  var
    slotProof = input.slotProof.mapIt( it.toBytes ).concat

  doAssert(slotProof.len == self.datasetDepth)
  # arrays are always flattened
  if ctx.pushInputU256Array(
    "slotProof".cstring,
    slotProof[0].addr,
    uint (slotProof[0].len * slotProof.len)) != ERR_OK:
      return failure("Failed to push slot proof")

  for s in input.samples:
    var
      merklePaths = s.merklePaths.mapIt( it.toBytes )
      data = s.cellData.mapIt( @(it.toBytes) ).concat

    if ctx.pushInputU256Array(
      "merklePaths".cstring,
      merklePaths[0].addr,
      uint (merklePaths[0].len * merklePaths.len)) != ERR_OK:
        return failure("Failed to push merkle paths")

    if ctx.pushInputU256Array(
      "cellData".cstring,
      data[0].addr,
      data.len.uint) != ERR_OK:
        return failure("Failed to push cell data")

  var
    proofPtr: ptr Proof = nil

  let proof =
    try:
      if (
        let res = self.backendCfg.proveCircuit(ctx, proofPtr.addr);
        res != ERR_OK) or
        proofPtr == nil:
        return failure("Failed to prove - err code: " & $res)

      proofPtr[]
    finally:
      if proofPtr != nil:
        proofPtr.addr.releaseProof()

  success proof

proc prove*[H](
  self: CircomCompat,
  input: ProofInputs[H]): ?!CircomProof =

  self.prove(self.normalizeInput(input))

proc verify*[H](
  self: CircomCompat,
  proof: CircomProof,
  inputs: ProofInputs[H]): ?!bool =
  ## Verify a proof using a ctx
  ##

  var
    proofPtr = unsafeAddr proof
    inputs = inputs.toCircomInputs()

  try:
    let res = verifyCircuit(proofPtr, inputs.addr, self.vkp)
    if res == ERR_OK:
      success true
    elif res == ERR_FAILED_TO_VERIFY_PROOF:
      success false
    else:
      failure("Failed to verify proof - err code: " & $res)
  finally:
    inputs.releaseCircomInputs()

proc init*(
  _: type CircomCompat,
  r1csPath      : string,
  wasmPath      : string,
  zkeyPath      : string = "",
  slotDepth     = DefaultMaxSlotDepth,
  datasetDepth  = DefaultMaxDatasetDepth,
  blkDepth      = DefaultBlockDepth,
  cellElms      = DefaultCellElms,
  numSamples    = DefaultSamplesNum): CircomCompat =
  ## Create a new ctx
  ##

  var cfg: ptr CircomBn254Cfg
  var zkey = if zkeyPath.len > 0: zkeyPath.cstring else: nil

  if initCircomConfig(
    r1csPath.cstring,
    wasmPath.cstring,
    zkey, cfg.addr) != ERR_OK or cfg == nil:
      if cfg != nil: cfg.addr.releaseCfg()
      raiseAssert("failed to initialize circom compat config")

  var
    vkpPtr: ptr VerifyingKey = nil

  if cfg.getVerifyingKey(vkpPtr.addr) != ERR_OK or vkpPtr == nil:
    if vkpPtr != nil: vkpPtr.addr.releaseKey()
    raiseAssert("Failed to get verifying key")

  CircomCompat(
    r1csPath    : r1csPath,
    wasmPath    : wasmPath,
    zkeyPath    : zkeyPath,
    slotDepth   : slotDepth,
    datasetDepth: datasetDepth,
    blkDepth    : blkDepth,
    cellElms    : cellElms,
    numSamples  : numSamples,
    backendCfg  : cfg,
    vkp         : vkpPtr)
