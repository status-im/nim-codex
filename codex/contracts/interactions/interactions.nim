import pkg/ethers
import ../clock
import ../marketplace
import ../market

export clock

type ContractInteractions* = ref object of RootObj
  clock*: Clock

method start*(self: ContractInteractions) {.async, base.} =
  discard

method stop*(self: ContractInteractions) {.async, base.} =
  discard
