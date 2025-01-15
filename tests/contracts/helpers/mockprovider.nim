import std/strutils
import std/tables

import pkg/ethers/provider
from codex/clock import SecondsSince1970

export provider.Block

type MockProvider* = ref object of Provider
  blocks: OrderedTableRef[int, Block]
  earliest: ?int
  latest: ?int

method getBlock*(
    provider: MockProvider, tag: BlockTag
): Future[?Block] {.async: (raises: [ProviderError]).} =
  try:
    if tag == BlockTag.latest:
      if latestBlock =? provider.latest:
        if provider.blocks.hasKey(latestBlock):
          return provider.blocks[latestBlock].some
    elif tag == BlockTag.earliest:
      if earliestBlock =? provider.earliest:
        if provider.blocks.hasKey(earliestBlock):
          return provider.blocks[earliestBlock].some
    elif tag == BlockTag.pending:
      raiseAssert "MockProvider does not yet support BlockTag.pending"
    else:
      let blockNumber = parseHexInt($tag)
      if provider.blocks.hasKey(blockNumber):
        return provider.blocks[blockNumber].some
    return Block.none
  except:
    return Block.none

proc updateEarliestAndLatest(provider: MockProvider, blockNumber: int) =
  if provider.earliest.isNone:
    provider.earliest = blockNumber.some
  provider.latest = blockNumber.some

proc addBlocks*(provider: MockProvider, blocks: OrderedTableRef[int, Block]) =
  for number, blk in blocks.pairs:
    if provider.blocks.hasKey(number):
      continue
    provider.updateEarliestAndLatest(number)
    provider.blocks[number] = blk

proc addBlock*(provider: MockProvider, number: int, blk: Block) =
  if not provider.blocks.hasKey(number):
    provider.updateEarliestAndLatest(number)
    provider.blocks[number] = blk

proc newMockProvider*(): MockProvider =
  MockProvider(
    blocks: newOrderedTable[int, Block](), earliest: int.none, latest: int.none
  )

proc newMockProvider*(blocks: OrderedTableRef[int, Block]): MockProvider =
  let provider = newMockProvider()
  provider.addBlocks(blocks)
  provider

proc newMockProvider*(
    numberOfBlocks: int,
    earliestBlockNumber: int,
    earliestBlockTimestamp: SecondsSince1970,
    timeIntervalBetweenBlocks: SecondsSince1970,
): MockProvider =
  var blocks = newOrderedTable[int, provider.Block]()
  var blockNumber = earliestBlockNumber
  var blockTime = earliestBlockTimestamp
  for i in 0 ..< numberOfBlocks:
    blocks[blockNumber] = provider.Block(
      number: blockNumber.u256.some, timestamp: blockTime.u256, hash: BlockHash.none
    )
    inc blockNumber
    inc blockTime, timeIntervalBetweenBlocks.int
  MockProvider(
    blocks: blocks,
    earliest: earliestBlockNumber.some,
    latest: (earliestBlockNumber + numberOfBlocks - 1).some,
  )
