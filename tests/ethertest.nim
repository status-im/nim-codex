import std/json
import pkg/ethers
import pkg/chronos

import ./asynctest
import ./checktest

## Unit testing suite that sets up an Ethereum testing environment.
## Injects a `ethProvider` instance, and a list of `accounts`.
## Calls the `evm_snapshot` and `evm_revert` methods to ensure that any
## changes to the blockchain do not persist.
template ethersuite*(name, body) =
  asyncchecksuite name:
    var ethProvider {.inject, used.}: JsonRpcProvider
    var accounts {.inject, used.}: seq[Address]
    var snapshot: JsonNode

    setup:
      ethProvider = JsonRpcProvider.new(
        "http://127.0.0.1:8545", pollingInterval = chronos.milliseconds(100)
      )
      snapshot = await send(ethProvider, "evm_snapshot")
      accounts = await ethProvider.listAccounts()

    teardown:
      await ethProvider.close()
      discard await send(ethProvider, "evm_revert", @[snapshot])

    body

export asynctest
export ethers except `%`
