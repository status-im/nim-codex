import pkg/chronos
import codex/contracts
import ../asynctest
import ../ethertest
import ./time
import ./helpers/mockprovider

# to see supportive information in the test output
# use `-d:"chronicles_enabled_topics:testProvider:DEBUG` option
# when compiling the test file
logScope:
  topics = "testProvider"

suite "Provider (Mock)":
  test "blockNumberForEpoch returns the earliest block when its timestamp " &
    "is greater than the given epoch time and the earliest block is not " &
    "block number 0 (genesis block)":
    let mockProvider = newMockProvider(
      numberOfBlocks = 10,
      earliestBlockNumber = 1,
      earliestBlockTimestamp = 10,
      timeIntervalBetweenBlocks = 10,
    )

    let (earliestBlockNumber, earliestTimestamp) =
      await mockProvider.blockNumberAndTimestamp(BlockTag.earliest)

    let epochTime = earliestTimestamp - 1

    let actual =
      await mockProvider.blockNumberForEpoch(epochTime.truncate(SecondsSince1970))

    check actual == earliestBlockNumber

  test "blockNumberForEpoch returns the earliest block when its timestamp " &
    "is equal to the given epoch time":
    let mockProvider = newMockProvider(
      numberOfBlocks = 10,
      earliestBlockNumber = 0,
      earliestBlockTimestamp = 10,
      timeIntervalBetweenBlocks = 10,
    )

    let (earliestBlockNumber, earliestTimestamp) =
      await mockProvider.blockNumberAndTimestamp(BlockTag.earliest)

    let epochTime = earliestTimestamp

    let actual =
      await mockProvider.blockNumberForEpoch(epochTime.truncate(SecondsSince1970))

    check earliestBlockNumber == 0.u256
    check actual == earliestBlockNumber

  test "blockNumberForEpoch returns the latest block when its timestamp " &
    "is equal to the given epoch time":
    let mockProvider = newMockProvider(
      numberOfBlocks = 10,
      earliestBlockNumber = 0,
      earliestBlockTimestamp = 10,
      timeIntervalBetweenBlocks = 10,
    )

    let (latestBlockNumber, latestTimestamp) =
      await mockProvider.blockNumberAndTimestamp(BlockTag.latest)

    let epochTime = latestTimestamp

    let actual =
      await mockProvider.blockNumberForEpoch(epochTime.truncate(SecondsSince1970))

    check actual == latestBlockNumber

ethersuite "Provider":
  proc mineNBlocks(provider: JsonRpcProvider, n: int) {.async.} =
    for _ in 0 ..< n:
      discard await provider.send("evm_mine")

  test "blockNumberForEpoch finds closest blockNumber for given epoch time":
    proc createBlockHistory(
        n: int, blockTime: int
    ): Future[seq[(UInt256, UInt256)]] {.async.} =
      var blocks: seq[(UInt256, UInt256)] = @[]
      for _ in 0 ..< n:
        await ethProvider.advanceTime(blockTime.u256)
        let (blockNumber, blockTimestamp) =
          await ethProvider.blockNumberAndTimestamp(BlockTag.latest)
        # collect blocknumbers and timestamps
        blocks.add((blockNumber, blockTimestamp))
      blocks

    proc printBlockNumbersAndTimestamps(blocks: seq[(UInt256, UInt256)]) =
      for (blockNumber, blockTimestamp) in blocks:
        debug "Block", blockNumber = blockNumber, timestamp = blockTimestamp

    type Expectations = tuple[epochTime: UInt256, expectedBlockNumber: UInt256]

    # We want to test that timestamps at the block boundaries, in the middle,
    # and towards lower and upper part of the range are correctly mapped to
    # the closest block number.
    # For example: assume we have the following two blocks with
    # the corresponding block numbers and timestamps:
    # block1: (291, 1728436100)
    # block2: (292, 1728436110)
    # To test that binary search correctly finds the closest block number,
    # we will test the following timestamps:
    # 1728436100 => 291
    # 1728436104 => 291
    # 1728436105 => 292
    # 1728436106 => 292
    # 1728436110 => 292
    proc generateExpectations(blocks: seq[(UInt256, UInt256)]): seq[Expectations] =
      var expectations: seq[Expectations] = @[]
      for i in 0 ..< blocks.len - 1:
        let (startNumber, startTimestamp) = blocks[i]
        let (endNumber, endTimestamp) = blocks[i + 1]
        let middleTimestamp = (startTimestamp + endTimestamp) div 2
        let lowerExpectation = (middleTimestamp - 1, startNumber)
        expectations.add((startTimestamp, startNumber))
        expectations.add(lowerExpectation)
        if middleTimestamp.truncate(int64) - startTimestamp.truncate(int64) <
            endTimestamp.truncate(int64) - middleTimestamp.truncate(int64):
          expectations.add((middleTimestamp, startNumber))
        else:
          expectations.add((middleTimestamp, endNumber))
        let higherExpectation = (middleTimestamp + 1, endNumber)
        expectations.add(higherExpectation)
        if i == blocks.len - 2:
          expectations.add((endTimestamp, endNumber))
      expectations

    proc printExpectations(expectations: seq[Expectations]) =
      debug "Expectations", numberOfExpectations = expectations.len
      for (epochTime, expectedBlockNumber) in expectations:
        debug "Expectation",
          epochTime = epochTime, expectedBlockNumber = expectedBlockNumber

    # mark the beginning of the history for our test
    await ethProvider.mineNBlocks(1)

    # set average block time - 10s - we use larger block time
    # then expected in Linea for more precise testing of the binary search
    let averageBlockTime = 10

    # create a history of N blocks
    let N = 10
    let blocks = await createBlockHistory(N, averageBlockTime)

    printBlockNumbersAndTimestamps(blocks)

    # generate expectations for block numbers
    let expectations = generateExpectations(blocks)
    printExpectations(expectations)

    # validate expectations
    for (epochTime, expectedBlockNumber) in expectations:
      debug "Validating",
        epochTime = epochTime, expectedBlockNumber = expectedBlockNumber
      let actualBlockNumber =
        await ethProvider.blockNumberForEpoch(epochTime.truncate(SecondsSince1970))
      check actualBlockNumber == expectedBlockNumber
