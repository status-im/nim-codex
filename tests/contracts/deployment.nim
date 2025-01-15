import std/os
import std/options
import pkg/ethers
import pkg/codex/contracts/marketplace

const hardhatMarketAddress =
  Address.init("0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44").get()
const hardhatMarketWithDummyVerifier =
  Address.init("0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f").get()
const marketAddressEnvName = "CODEX_MARKET_ADDRESS"

proc address*(_: type Marketplace, dummyVerifier = false): Address =
  if existsEnv(marketAddressEnvName):
    without address =? Address.init(getEnv(marketAddressEnvName)):
      raiseAssert "Invalid env. variable marketplace contract address"

    return address

  if dummyVerifier: hardhatMarketWithDummyVerifier else: hardhatMarketAddress
