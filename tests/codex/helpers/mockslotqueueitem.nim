import pkg/codex/contracts/requests
import pkg/codex/sales/slotqueue

type MockSlotQueueItem* = object
  requestId*: RequestId
  slotIndex*: uint16
  slotSize*: UInt256
  duration*: UInt256
  reward*: UInt256
  collateral*: UInt256
  expiry*: UInt256
  seen*: bool

proc toSlotQueueItem*(item: MockSlotQueueItem): SlotQueueItem =
  SlotQueueItem.init(
    requestId = item.requestId,
    slotIndex = item.slotIndex,
    ask = StorageAsk(
            slotSize: item.slotSize,
            duration: item.duration,
            reward: item.reward,
            collateral: item.collateral
          ),
    expiry = item.expiry,
    seen = item.seen
  )
