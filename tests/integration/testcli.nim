import std/unittest
import std/tempfiles
import codex/conf
import codex/utils/fileutils
import ./nodes
import ../examples

suite "Command line interface":

  let key = "4242424242424242424242424242424242424242424242424242424242424242"

  test "complains when persistence is enabled without ethereum account":
    let node = startNode(@[
      "persistence"
    ])
    node.waitUntilOutput("Persistence enabled, but no Ethereum account was set")
    node.stop()

  test "complains when ethereum private key file has wrong permissions":
    let unsafeKeyFile = genTempPath("", "")
    discard unsafeKeyFile.writeFile(key, 0o666)
    let node = startNode(@[
      "persistence",
      "--eth-private-key=" & unsafeKeyFile])
    node.waitUntilOutput("Ethereum private key file does not have safe file permissions")
    node.stop()
    discard removeFile(unsafeKeyFile)

  let
    marketplaceArg = "--marketplace-address=" & $EthAddress.example
    expectedDownloadInstruction = "Proving circuit files are not found. Please run the following to download them:"

  test "suggests downloading of circuit files when persistence is enabled without accessible r1cs file":
    let node = startNode(@["persistence", "prover", marketplaceArg])
    node.waitUntilOutput(expectedDownloadInstruction)
    node.stop()

  test "suggests downloading of circuit files when persistence is enabled without accessible wasm file":
    let node = startNode(@[
      "persistence",
      "prover",
      marketplaceArg,
      "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs"
    ])
    node.waitUntilOutput(expectedDownloadInstruction)
    node.stop()

  test "suggests downloading of circuit files when persistence is enabled without accessible zkey file":
    let node = startNode(@[
      "persistence",
      "prover",
      marketplaceArg,
      "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs",
      "--circom-wasm=tests/circuits/fixtures/proof_main.wasm"
    ])
    node.waitUntilOutput(expectedDownloadInstruction)
    node.stop()
