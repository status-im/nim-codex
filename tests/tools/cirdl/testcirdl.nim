import std/os
import std/osproc
import std/options
import pkg/chronos
import pkg/codex/contracts
import ../../asynctest
import ../../contracts/deployment

suite "tools/cirdl":
  const
    cirdl = "build" / "cirdl"
    workdir = "."

  test "circuit download tool":
    let
      circuitPath = "testcircuitpath"
      rpcEndpoint = "ws://localhost:8545"
      marketplaceAddress = Marketplace.address

    discard existsOrCreateDir(circuitPath)

    let args = [circuitPath, rpcEndpoint, $marketplaceAddress]

    let process = osproc.startProcess(
      cirdl,
      workdir,
      args,
      options={poParentStreams}
    )

    let returnCode = process.waitForExit()
    check returnCode == 0

    check:
      fileExists(circuitPath/"proof_main_verification_key.json")
      fileExists(circuitPath/"proof_main.r1cs")
      fileExists(circuitPath/"proof_main.wasm")
      fileExists(circuitPath/"proof_main.zkey")

    removeDir(circuitPath)
