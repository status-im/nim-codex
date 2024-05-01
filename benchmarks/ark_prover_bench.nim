import std/[sequtils, strutils, strformat, os, options, importutils, times, os, strutils, terminal]

import pkg/questionable
import pkg/questionable/results
import pkg/datastore

import pkg/codex/[rng, stores, merkletree, codextypes, slots]
import pkg/codex/utils/[json, poseidon2digest]
import pkg/codex/slots/[builder, sampler/utils, backends/helpers]
import pkg/constantine/math/[arithmetic, io/io_bigints, io/io_fields]

import create_circuits

type CircuitFiles* = object
  r1cs*: string
  wasm*: string
  zkey*: string
  inputs*: string

template benchmark(benchmarkName: string, blk: untyped) =
  let nn = 5
  var vals = newSeqOfCap[float](nn)
  for i in 1 .. nn:
    block:
      let t0 = epochTime()
      `blk`
      let elapsed = epochTime() - t0
      vals.add elapsed

  var elapsedStr = ""
  for v in vals:
    elapsedStr &= ", " & v.formatFloat(format = ffDecimal, precision = 3)
  stdout.styledWriteLine(
    fgGreen, "CPU Time [", benchmarkName, "] ", "avg(", $nn, "): ", elapsedStr, " s"
  )

proc runArkCircom(args: CircArgs, files: CircuitFiles) =
  echo "Loading sample proof..."
  var
    inputData = files.inputs.readFile()
    inputJson = !JsonNode.parse(inputData)
    proofInputs = Poseidon2Hash.jsonToProofInput(inputJson)
    circom = CircomCompat.init(
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

  var proof: CircomProof
  benchmark fmt"prover":
    proof = circom.prove(proofInputs).tryGet

  var verRes: bool
  benchmark fmt"verify":
    verRes = circom.verify(proof, proofInputs).tryGet
  echo "verify result: ", verRes

  when false:
    proofInputs.slotIndex = 1 # change slot index

    let proof = circom.prove(proofInputs).tryGet
    echo "verify bad result: ", circom.verify(proof, proofInputs).tryGet

proc runRapidSnark(args: CircArgs, files: CircuitFiles) =
  # time rapidsnark ${CIRCUIT_MAIN}.zkey witness.wtns proof.json public.json

  echo "generating the witness..."

proc runBenchmark(args: CircArgs) =
  ## execute benchmarks given a set of args
  ## will create a folder in `benchmarks/circuit_bench_$(args)`
  ## 

  let env = createCircuit(args)

  ## TODO: copy over testcircomcompat proving
  let files = CircuitFiles(
    r1cs: env.dir / fmt"{env.name}.r1cs",
    wasm: env.dir / fmt"{env.name}.wasm",
    zkey: env.dir / fmt"{env.name}.zkey",
    inputs: env.dir / fmt"input.json",
  )

  runArkCircom(args, files)

proc startBenchmarks*() =
  echo "Running benchmark"
  # setup()
  checkEnv()
  var args = CircArgs(
    depth: 32, # maximum depth of the slot tree 
    maxslots: 256, # maximum number of slots  
    cellsize: 2048, # cell size in bytes 
    blocksize: 65536, # block size in bytes 
    nsamples: 1, # number of samples to prove
    entropy: 1234567, # external randomness
    seed: 12345, # seed for creating fake data
    nslots: 11, # number of slots in the dataset
    index: 3, # which slot we prove (0..NSLOTS-1)
    ncells: 512, # number of cells in this slot
  )

  for i in 1 .. 9:
    args.nsamples = i
    stdout.styledWriteLine(fgYellow, "\nbenchmarking args: ", $args)
    args.runBenchmark()

  # for i in 1..16:
  #   args.nsamples = 10*i
  #   stdout.styledWriteLine(fgYellow, "\nbenchmarking args: ", $args)
  #   args.runBenchmark()

when isMainModule:
  startBenchmarks()
