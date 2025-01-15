import pkg/ethers/provider
import pkg/chronos
import pkg/questionable

import ../logutils

from ../clock import SecondsSince1970

logScope:
  topics = "marketplace onchain provider"

proc raiseProviderError(message: string) {.raises: [ProviderError].} =
  raise newException(ProviderError, message)

proc blockNumberAndTimestamp*(
    provider: Provider, blockTag: BlockTag
): Future[(UInt256, UInt256)] {.async: (raises: [ProviderError]).} =
  without latestBlock =? await provider.getBlock(blockTag):
    raiseProviderError("Could not get latest block")

  without latestBlockNumber =? latestBlock.number:
    raiseProviderError("Could not get latest block number")

  return (latestBlockNumber, latestBlock.timestamp)

proc binarySearchFindClosestBlock(
    provider: Provider, epochTime: int, low: UInt256, high: UInt256
): Future[UInt256] {.async: (raises: [ProviderError]).} =
  let (_, lowTimestamp) = await provider.blockNumberAndTimestamp(BlockTag.init(low))
  let (_, highTimestamp) = await provider.blockNumberAndTimestamp(BlockTag.init(high))
  if abs(lowTimestamp.truncate(int) - epochTime) <
      abs(highTimestamp.truncate(int) - epochTime):
    return low
  else:
    return high

proc binarySearchBlockNumberForEpoch(
    provider: Provider,
    epochTime: UInt256,
    latestBlockNumber: UInt256,
    earliestBlockNumber: UInt256,
): Future[UInt256] {.async: (raises: [ProviderError]).} =
  var low = earliestBlockNumber
  var high = latestBlockNumber

  while low <= high:
    if low == 0 and high == 0:
      return low
    let mid = (low + high) div 2
    let (midBlockNumber, midBlockTimestamp) =
      await provider.blockNumberAndTimestamp(BlockTag.init(mid))

    if midBlockTimestamp < epochTime:
      low = mid + 1
    elif midBlockTimestamp > epochTime:
      high = mid - 1
    else:
      return midBlockNumber
  # NOTICE that by how the binary search is implemented, when it finishes
  # low is always greater than high - this is why we use high, where
  # intuitively we would use low:
  await provider.binarySearchFindClosestBlock(
    epochTime.truncate(int), low = high, high = low
  )

proc blockNumberForEpoch*(
    provider: Provider, epochTime: SecondsSince1970
): Future[UInt256] {.async: (raises: [ProviderError]).} =
  let epochTimeUInt256 = epochTime.u256
  let (latestBlockNumber, latestBlockTimestamp) =
    await provider.blockNumberAndTimestamp(BlockTag.latest)
  let (earliestBlockNumber, earliestBlockTimestamp) =
    await provider.blockNumberAndTimestamp(BlockTag.earliest)

  # Initially we used the average block time to predict
  # the number of blocks we need to look back in order to find
  # the block number corresponding to the given epoch time. 
  # This estimation can be highly inaccurate if block time
  # was changing in the past or is fluctuating and therefore
  # we used that information initially only to find out
  # if the available history is long enough to perform effective search.
  # It turns out we do not have to do that. There is an easier way.
  #
  # First we check if the given epoch time equals the timestamp of either
  # the earliest or the latest block. If it does, we just return the
  # block number of that block.
  #
  # Otherwise, if the earliest available block is not the genesis block, 
  # we should check the timestamp of that earliest block and if it is greater
  # than the epoch time, we should issue a warning and return
  # that earliest block number.
  # In all other cases, thus when the earliest block is not the genesis
  # block but its timestamp is not greater than the requested epoch time, or
  # if the earliest available block is the genesis block, 
  # (which means we have the whole history available), we should proceed with
  # the binary search.
  #
  # Additional benefit of this method is that we do not have to rely
  # on the average block time, which not only makes the whole thing
  # more reliable, but also easier to test.

  # Are lucky today?
  if earliestBlockTimestamp == epochTimeUInt256:
    return earliestBlockNumber
  if latestBlockTimestamp == epochTimeUInt256:
    return latestBlockNumber

  if earliestBlockNumber > 0 and earliestBlockTimestamp > epochTimeUInt256:
    let availableHistoryInDays =
      (latestBlockTimestamp - earliestBlockTimestamp) div 1.days.secs.u256
    warn "Short block history detected.",
      earliestBlockTimestamp = earliestBlockTimestamp, days = availableHistoryInDays
    return earliestBlockNumber

  return await provider.binarySearchBlockNumberForEpoch(
    epochTimeUInt256, latestBlockNumber, earliestBlockNumber
  )

proc pastBlockTag*(
    provider: Provider, blocksAgo: int
): Future[BlockTag] {.async: (raises: [ProviderError]).} =
  let head = await provider.getBlockNumber()
  return BlockTag.init(head - blocksAgo.abs.u256)
