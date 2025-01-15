import pkg/codex/sales/salesagent

type MockSalesAgent = ref object of SalesAgent
  fulfilledCalled*: bool
  failedCalled*: bool
  slotFilledCalled*: bool

method onFulfilled*(agent: SalesAgent, requestId: RequestId) =
  fulfilledCalled = true

method onFailed*(agent: SalesAgent, requestId: RequestId) =
  failedCalled = true

method onSlotFilled*(
    agent: SalesAgent, requestId: RequestId, slotIndex: UInt256
) {.base.} =
  slotFilledCalled = true
