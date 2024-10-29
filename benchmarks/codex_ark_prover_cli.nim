import std/[sequtils, strformat, os, options, importutils]
import std/[times, os, strutils, terminal, parseopt]

import pkg/questionable
import pkg/questionable/results
import pkg/datastore

import pkg/codex/[rng, stores, merkletree, codextypes, slots]
import pkg/codex/utils/[json, poseidon2digest]
import pkg/codex/slots/[builder, sampler/utils, backends/helpers]
import pkg/constantine/math/[arithmetic, io/io_bigints, io/io_fields]

import ./utils
import ./create_circuits

type CircuitFiles* = object
  r1cs*: string
  wasm*: string
  zkey*: string
  inputs*: string
  dir*: string
  circName*: string

proc runArkCircom(
    args: CircuitArgs, files: CircuitFiles, proofInputs: ProofInputs[Poseidon2Hash]
) =
  echo "Loading sample proof..."
  var circom = CircomCompat.init(
    files.r1cs,
    files.wasm,
    files.zkey,
    slotDepth = args.depth,
    numSamples = args.nsamples,
  )
  defer:
    circom.release() # this comes from the rust FFI

  echo "Sample proof loaded..."
  echo "Proving..."

  var proof: CircomProof = circom.prove(proofInputs).tryGet

  var verRes: bool = circom.verify(proof, proofInputs).tryGet
  if not verRes:
    echo "verification failed"
    quit 100

proc printHelp() =
  echo "usage:"
  echo "  ./codex_ark_prover_cli [options] "
  echo ""
  echo "available options:"
  echo " -h, --help                         : print this help"
  echo " -v, --verbose                      : verbose output (print the actual parameters)"
  echo "     --r1cs:$FILE                   : r1cs file path"
  echo "     --wasm:$FILE                   : wasm file path"
  echo "     --zkey:$FILE                   : zkey file path"
  echo "     --inputs:$FILE                 : inputs.json file path"
  # echo " -S, --seed       = <seed>          : seed to generate the fake data (eg. 12345)"
  echo ""
  echo "Must provide files options. Use either:"
  echo "  --dir:$CIRCUIT_DIR --name:$CIRCUIT_NAME"
  echo "or:"
  echo "  --r1cs:$R1CS --wasm:$WASM --zkey:$ZKEY"
  echo ""

  quit(1)

proc parseCliOptions(args: var CircuitArgs, files: var CircuitFiles) =
  var argCtr: int = 0
  template expectPath(val: string): string =
    if val == "":
      echo "ERROR: expected path a but got empty for: ", key
      printHelp()
    val.absolutePath

  for kind, key, value in getOpt():
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
      of "d", "depth":
        args.depth = parseInt(value)
      of "r1cs":
        files.r1cs = value.expectPath()
      of "wasm":
        files.wasm = value.expectPath()
      of "zkey":
        files.zkey = value.expectPath()
      of "inputs":
        files.inputs = value.expectPath()
      of "dir":
        files.dir = value.expectPath()
      of "name":
        files.circName = value
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

  var
    args = CircuitArgs()
    files = CircuitFiles()

  parseCliOptions(args, files)

  let dir =
    if files.dir != "":
      files.dir
    else:
      getCurrentDir()
  if files.circName != "":
    if files.r1cs == "":
      files.r1cs = dir / fmt"{files.circName}.r1cs"
    if files.wasm == "":
      files.wasm = dir / fmt"{files.circName}.wasm"
    if files.zkey == "":
      files.zkey = dir / fmt"{files.circName}.zkey"

  if files.inputs == "":
    files.inputs = dir / fmt"input.json"

  echo "Got file args: ", files

  var fileErrors = false
  template checkFile(file, name: untyped) =
    if file == "" or not file.fileExists():
      echo "\nERROR: must provide `" & name & "` file"
      fileErrors = true

  checkFile files.inputs, "inputs.json"
  checkFile files.r1cs, "r1cs"
  checkFile files.wasm, "wasm"
  checkFile files.zkey, "zkey"

  if fileErrors:
    echo "ERROR: couldn't find all files"
    printHelp()

  var
    inputData = files.inputs.readFile()
    inputs: JsonNode = !JsonNode.parse(inputData)

  # sets default values for these args
  if args.depth == 0:
    args.depth = codextypes.DefaultMaxSlotDepth
    # maximum depth of the slot tree
  if args.maxslots == 0:
    args.maxslots = 256
    # maximum number of slots

  # sets number of samples to take
  if args.nsamples == 0:
    args.nsamples = 1
    # number of samples to prove

  # overrides the input.json params
  if args.entropy != 0:
    inputs["entropy"] = %($args.entropy)
  if args.nslots != 0:
    inputs["nSlotsPerDataSet"] = %args.nslots
  if args.index != 0:
    inputs["slotIndex"] = %args.index
  if args.ncells != 0:
    inputs["nCellsPerSlot"] = %args.ncells

  var proofInputs = Poseidon2Hash.jsonToProofInput(inputs)

  echo "Got args: ", args
  runArkCircom(args, files, proofInputs)

when isMainModule:
  run()
