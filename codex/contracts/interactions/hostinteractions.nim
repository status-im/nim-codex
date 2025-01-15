import pkg/chronos

import ../../logutils
import ../../sales
import ./interactions

export sales
export logutils

type HostInteractions* = ref object of ContractInteractions
  sales*: Sales

proc new*(_: type HostInteractions, clock: Clock, sales: Sales): HostInteractions =
  ## Create a new HostInteractions instance
  ##
  HostInteractions(clock: clock, sales: sales)

method start*(self: HostInteractions) {.async.} =
  await procCall ContractInteractions(self).start()
  await self.sales.start()

method stop*(self: HostInteractions) {.async.} =
  await self.sales.stop()
  await procCall ContractInteractions(self).start()
