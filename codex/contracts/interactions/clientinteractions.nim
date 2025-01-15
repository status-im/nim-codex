import pkg/ethers

import ../../purchasing
import ../../logutils
import ../market
import ../clock
import ./interactions

export purchasing
export logutils

type ClientInteractions* = ref object of ContractInteractions
  purchasing*: Purchasing

proc new*(
    _: type ClientInteractions, clock: OnChainClock, purchasing: Purchasing
): ClientInteractions =
  ClientInteractions(clock: clock, purchasing: purchasing)

proc start*(self: ClientInteractions) {.async.} =
  await procCall ContractInteractions(self).start()
  await self.purchasing.start()

proc stop*(self: ClientInteractions) {.async.} =
  await self.purchasing.stop()
  await procCall ContractInteractions(self).stop()
