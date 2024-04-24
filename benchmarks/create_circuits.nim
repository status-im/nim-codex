import std/strutils
import std/os

proc createCircuits() =
  let cmds = """
    ${NIMCLI_DIR}/cli $CLI_ARGS -v --circom=${CIRCUIT_MAIN}.circom --output=input.json
    circom --r1cs --wasm --O2 -l${CIRCUIT_DIR} ${CIRCUIT_MAIN}.circom
    NODE_OPTIONS="--max-old-space-size=8192" snarkjs groth16 setup ${CIRCUIT_MAIN}.r1cs $PTAU_PATH ${CIRCUIT_MAIN}_0000.zkey
    echo "some_entropy_75289v3b7rcawcsyiur" | NODE_OPTIONS="--max-old-space-size=8192" snarkjs zkey contribute ${CIRCUIT_MAIN}_0000.zkey ${CIRCUIT_MAIN}_0001.zkey --name="1st Contributor Name"
    """.splitLines()

    # rm ${CIRCUIT_MAIN}_0000.zkey
    # mv ${CIRCUIT_MAIN}_0001.zkey ${CIRCUIT_MAIN}.zkey

let nimCircuitRef = "vendor/codex-storage-proofs-circuits/reference/nim/proof_input/cli"

proc setProjDir(prev = getCurrentDir()) =
  if not "codex.nimble".fileExists():
    setCurrentDir("..")
    if prev == getCurrentDir():
      echo "\nERROR: Codex project folder not found (could not find codex.nimble)"
      echo "\nBenchmark must be run from within the Codex project folder"
      quit 1
    setProjDir()

setProjDir()

if not nimCircuitRef.fileExists:
  echo "Nim Circuit ref exe not found"


echo "huzzah"