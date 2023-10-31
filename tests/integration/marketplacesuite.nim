import std/times
import pkg/chronos
import pkg/codex/contracts/marketplace as mp
import pkg/codex/periods
import ./multinodes

export mp
export multinodes

template marketplacesuite*(name: string, startNodes: Nodes, body: untyped) =

  multinodesuite name, startNodes:

    var marketplace {.inject, used.}: Marketplace
    var period: uint64
    var token {.inject, used.}: Erc20Token

    proc advanceToNextPeriod() {.async.} =
      let periodicity = Periodicity(seconds: period.u256)
      let currentPeriod = periodicity.periodOf(ethProvider.currentTime())
      let nextPeriod = periodicity.periodEnd(currentPeriod)
      echo "advancing to next period start at ", nextPeriod + 1
      await ethProvider.advanceTimeTo(nextPeriod + 1)

    proc periods(p: int): uint64 =
      p.uint64 * period

    template eventuallyP(condition: untyped, totalProofs: int, sleep: int): bool =
      proc e: Future[bool] {.async.} =
        for i in 0..<totalProofs.int:
          if condition:
            echo "condition is true, returning, ", i, " out of ", totalProofs.int
            return true
          else:
            echo $(getTime().toUnix) & " advancing to the next period... ", i, " out of ", totalProofs.int
            await advanceToNextPeriod()
            await sleepAsync(chronos.seconds(sleep))

        return false

      let r = await e()
      echo "returning result of eventuallyP: ", r
      r

    proc createAvailabilities(datasetSize: int, duration: uint64) =
      # post availability to each provider
      for i in 0..<providers().len:
        let provider = providers()[i].node.client

        discard provider.postAvailability(
          size=datasetSize.u256, # should match 1 slot only
          duration=duration.u256,
          minPrice=300.u256,
          maxCollateral=200.u256
        )

    proc requestStorage(client: CodexClient,
                        cid: Cid,
                        # provider: JsonRpcProvider,
                        proofProbability: uint64 = 1,
                        duration: uint64 = 12.periods,
                        expiry: uint64 = 4.periods,
                        nodes = providers().len,
                        tolerance = 0): Future[PurchaseId] {.async.} =

      # let cid = client.upload(byteutils.toHex(data)).get
      let expiry = (await ethProvider.currentTime()) + expiry.u256

      # avoid timing issues by filling the slot at the start of the next period
      await advanceToNextPeriod()

      let id = client.requestStorage(
        cid,
        expiry=expiry,
        duration=duration.u256,
        proofProbability=proofProbability.u256,
        collateral=100.u256,
        reward=400.u256,
        nodes=nodes.uint,
        tolerance=tolerance.uint
      ).get

      return id

    setup:
      marketplace = Marketplace.new(Marketplace.address, ethProvider.getSigner())
      let tokenAddress = await marketplace.token()
      token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
      let config = await mp.config(marketplace)
      period = config.proofs.period.truncate(uint64)



      # Our Hardhat configuration does use automine, which means that time tracked by `provider.currentTime()` is not
      # advanced until blocks are mined and that happens only when transaction is submitted.
      # As we use in tests provider.currentTime() which uses block timestamp this can lead to synchronization issues.
      await ethProvider.advanceTime(1.u256)

    body