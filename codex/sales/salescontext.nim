import pkg/questionable
import pkg/questionable/results

import ../market
import ../clock
import ./slotqueue
import ./reservations
import ../blocktype as bt

type
  SalesContext* = ref object
    market*: Market
    clock*: Clock
    # Sales-level callbacks. Closure will be overwritten each time a slot is
    # processed.
    onStore*: ?OnStore
    onClear*: ?OnClear
    onSale*: ?OnSale
    onProve*: ?OnProve
    onExpiryUpdate*: ?OnExpiryUpdate
    reservations*: Reservations
    slotQueue*: SlotQueue
    simulateProofFailures*: int

  BlocksCb* = proc(blocks: seq[bt.Block]): Future[?!void] {.gcsafe, async.}
  OnStore* = proc(request: StorageRequest,
                  slot: UInt256,
                  blocksCb: BlocksCb): Future[?!void] {.gcsafe, async.}
  OnProve* = proc(slot: Slot, challenge: ProofChallenge): Future[?!seq[byte]] {.gcsafe, async.}
  OnExpiryUpdate* = proc(rootCid: string, expiry: SecondsSince1970): Future[?!void] {.gcsafe, async.}
  OnClear* = proc(request: StorageRequest,
                  slotIndex: UInt256) {.gcsafe, raises: [].}
  OnSale* = proc(request: StorageRequest,
                 slotIndex: UInt256) {.gcsafe, raises: [].}
