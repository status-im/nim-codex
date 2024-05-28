import std/[sequtils, strformat, os, options, importutils]
import std/[times, os, strutils, terminal, parseopt, json]

import pkg/questionable
import pkg/questionable/results
import pkg/serde/json except `%*`, `%`

import pkg/circomcompat
import pkg/poseidon2/io

import ./utils
import ./create_circuits
import ./clitypes

type CircomCircuit* = object
  r1csPath*: string
  wasmPath*: string
  zkeyPath*: string
  inputsPath*: string
  dir*: string
  circName*: string
  backendCfg: ptr CircomBn254Cfg
  vkp*: ptr VerifyingKey

proc release*(self: CircomCircuit) =
  ## Release the ctx
  ##
  if not isNil(self.backendCfg):
    self.backendCfg.unsafeAddr.releaseCfg()
  if not isNil(self.vkp):
    self.vkp.unsafeAddr.release_key()

proc initialize*(self: var CircomCircuit) =
  ## Create a new ctx
  ##

  var cfg: ptr CircomBn254Cfg
  var zkey = if self.zkeyPath.len > 0: self.zkeyPath.cstring else: nil

  if initCircomConfig(
    self.r1csPath.cstring, self.wasmPath.cstring, self.zkeyPath.cstring, cfg.addr
  ) != ERR_OK or cfg == nil:
    if cfg != nil:
      cfg.addr.releaseCfg()
    raiseAssert("failed to initialize circom compat config")

  var vkpPtr: ptr VerifyingKey = nil

  if cfg.getVerifyingKey(vkpPtr.addr) != ERR_OK or vkpPtr == nil:
    if vkpPtr != nil:
      vkpPtr.addr.releaseKey()
    raiseAssert("Failed to get verifying key")

  self.backendCfg = cfg
  self.vkp = vkpPtr

proc parseJsons(
  ctx: var ptr CircomCompatCtx,
  key: string,
  value: JsonNode
) =
    if value.kind == JString:
      var num = value.parseBigInt()
      echo "Big NUM: ", num
      if ctx.pushInputU256Array(key.cstring, num.addr, 1) != ERR_OK:
        raise newException(ValueError, "Failed to push BigInt from dec string")
    elif value.kind == JInt:
      # var num = value.getInt().int32
      # if ctx.pushInputI32(key.cstring, num) != ERR_OK:
      #   raise newException(ValueError, "Failed to push JInt")
      var num = value.getInt().uint64
      echo "NUM: ", num, " orig: ", value.getInt()
      if ctx.pushInputU64(key.cstring, num) != ERR_OK:
        raise newException(ValueError, "Failed to push JInt")
    elif value.kind == JArray:
      for item in value:
        ctx.parseJsons(key, item)
    else:
      echo "unhandled val: " & $value
      raise newException(ValueError, "Failed to push Json of " & $value.kind)

proc initCircomCtx*(
  self: CircomCircuit, input: JsonNode
): ptr CircomCompatCtx =
  # TODO: All parameters should match circom's static parametter
  var ctx: ptr CircomCompatCtx

  if initCircomCompat(self.backendCfg, addr ctx) != ERR_OK or ctx == nil:
    raiseAssert("failed to initialize CircomCircuit ctx")

  for key, value in input:
    echo "KEY: ", key, " VAL: ", value.kind
    ctx.parseJsons(key, value)
  
  return ctx

proc prove*(
  self: CircomCircuit, input: JsonNode
): CircomProof =
  ## Encode buffers using a ctx
  ##

  var ctx = initCircomCtx(self, input)
  defer:
    if ctx != nil:
      ctx.addr.releaseCircomCompat()

  var proofPtr: ptr Proof = nil

  let proof: Proof =
    try:
      if (let res = self.backendCfg.proveCircuit(ctx, proofPtr.addr); res != ERR_OK) or
          proofPtr == nil:
        echo "Failed to prove - err code: " & $res

      proofPtr[]
    finally:
      if proofPtr != nil:
        proofPtr.addr.releaseProof()

  # echo "Proof:"
  # echo proof
  echo "\nProof:json: "
  let g16proof: Groth16Proof = proof.toGroth16Proof()
  echo pretty(%*(g16proof))
  return proof

proc verify*(
  self: CircomCircuit,
  jsonInput: JsonNode,
  proof: CircomProof,
): bool =
  ## Verify a proof using a ctx

  var ctx = initCircomCtx(self, jsonInput)
  defer:
    if ctx != nil:
      ctx.addr.releaseCircomCompat()

  var inputs: ptr Inputs

  doAssert ctx.get_pub_inputs(inputs.addr) == ERR_OK

  try:
    let res = verifyCircuit(proof.unsafeAddr, inputs, self.vkp)

    if res == ERR_OK:
      result = true
    elif res == ERR_FAILED_TO_VERIFY_PROOF:
      result = false
    else:
      raise newException(ValueError, "Failed to verify proof - err code: " & $res)

    echo "proof verification result: ", result
  finally:
    release_inputs(inputs.addr)


proc printHelp() =
  echo "usage:"
  echo "  ./circom_ark_prover_cli [options] "
  echo ""
  echo "available options:"
  echo " -h, --help                         : print this help"
  echo " -v, --verbose                      : verbose output (print the actual parameters)"
  echo "     --r1cs:$FILE                   : r1cs file path"
  echo "     --wasm:$FILE                   : wasm file path"
  echo "     --zkey:$FILE                   : zkey file path"
  echo "     --inputs:$FILE                 : inputs.json file path"
  echo ""
  echo "Must provide files options. Use either:"
  echo "  --dir:$CIRCUIT_DIR --name:$CIRCUIT_NAME"
  echo "or:"
  echo "  --r1cs:$R1CS --wasm:$WASM --zkey:$ZKEY"
  echo ""

  quit(1)

proc parseCliOptions(self: var CircomCircuit) =
  var argCtr: int = 0
  template expectPath(val: string): string =
    if val == "":
      echo "ERROR: expected path a but got empty for: ", key
      printHelp()
    val.absolutePath

  let params =
    @[
      "--dir:benchmarks/circuit_bench_depth32_maxslots256_cellsize2048_blocksize65536_nsamples1_entropy1234567_seed12345_nslots11_ncells512_index3/",
      "--name:proof_main"
    ]

  for kind, key, value in getOpt(params):
    case kind

    # Positional arguments
    of cmdArgument:
      echo "\nERROR: got unexpected arg: ", key, "\n"
      printHelp()

    # Switches
    of cmdLongOption, cmdShortOption:
      case key
      of "h", "help":
        printHelp()
      of "r1cs":
        self.r1csPath = value.expectPath()
      of "wasm":
        self.wasmPath = value.expectPath()
      of "zkey":
        self.zkeyPath = value.expectPath()
      of "inputs":
        self.inputsPath = value.expectPath()
      of "dir":
        self.dir = value.expectPath()
      of "name":
        self.circName = value
      else:
        echo "Unknown option: ", key
        echo "use --help to get a list of options"
        quit()
    of cmdEnd:
      discard

proc run*() =
  ## Run Codex Ark/Circom based prover
  ## 
  echo "Running prover"

  # prove wasm ${CIRCUIT_MAIN}.zkey witness.wtns proof.json public.json

  var self = CircomCircuit()

  parseCliOptions(self)

  let dir =
    if self.dir != "":
      self.dir
    else:
      getCurrentDir()
  if self.circName != "":
    if self.r1csPath == "":
      self.r1csPath = dir / fmt"{self.circName}.r1cs"
    if self.wasmPath == "":
      self.wasmPath = dir / fmt"{self.circName}.wasm"
    if self.zkeyPath == "":
      self.zkeyPath = dir / fmt"{self.circName}.zkey"

  if self.inputsPath == "":
    self.inputsPath = dir / fmt"input.json"

  echo "Got file args: ", self

  var fileErrors = false
  template checkFile(file, name: untyped) =
    if file == "" or not file.fileExists():
      echo "\nERROR: must provide `" & name & "` file"
      fileErrors = true

  checkFile self.inputsPath, "inputs.json"
  checkFile self.r1csPath, "r1cs"
  checkFile self.wasmPath, "wasm"
  checkFile self.zkeyPath, "zkey"

  if fileErrors:
    echo "ERROR: couldn't find all files"
    printHelp()

  self.initialize()

  var
    inputData = self.inputsPath.readFile()
    inputs: JsonNode = !JsonNode.parse(inputData)

  let proof = prove(self, inputs)
  let verified = verify(self, inputs, proof)

when isMainModule:
  run()
