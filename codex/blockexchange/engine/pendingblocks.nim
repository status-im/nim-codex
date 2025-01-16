## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables
import std/monotimes

import pkg/upraises

push: {.upraises: [].}

import pkg/chronos
import pkg/libp2p
import pkg/metrics

import ../protobuf/blockexc
import ../../blocktype
import ../../logutils

logScope:
  topics = "codex pendingblocks"

declareGauge(codex_block_exchange_pending_block_requests, "codex blockexchange pending block requests")
declareGauge(codex_block_exchange_retrieval_time_us, "codex blockexchange block retrieval time us")

const
  DefaultBlockTimeout* = 10.minutes

type
  BlockReq* = object
    handle*: Future[Block]
    inFlight*: bool
    startTime*: int64

  PendingBlocksManager* = ref object of RootObj
    blocks*: Table[BlockAddress, BlockReq] # pending Block requests

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  codex_block_exchange_pending_block_requests.set(p.blocks.len.int64)

proc getWantHandle*(
  p: PendingBlocksManager,
  address: BlockAddress,
  timeout = DefaultBlockTimeout,
  inFlight = false): Future[Block] {.async.} =
  ## Add an event for a block
  ##

  try:
    if address notin p.blocks:
      p.blocks[address] = BlockReq(
        handle: newFuture[Block]("pendingBlocks.getWantHandle"),
        inFlight: inFlight,
        startTime: getMonoTime().ticks)

    p.updatePendingBlockGauge()
    return await p.blocks[address].handle.wait(timeout)
  except CancelledError as exc:
    trace "Blocks cancelled", exc = exc.msg, address
    raise exc
  except CatchableError as exc:
    error "Pending WANT failed or expired", exc = exc.msg
    # no need to cancel, it is already cancelled by wait()
    raise exc
  finally:
    p.blocks.del(address)
    p.updatePendingBlockGauge()

proc getWantHandle*(
  p: PendingBlocksManager,
  cid: Cid,
  timeout = DefaultBlockTimeout,
  inFlight = false): Future[Block] =
  p.getWantHandle(BlockAddress.init(cid), timeout, inFlight)

proc resolve*(
  p: PendingBlocksManager,
  blocksDelivery: seq[BlockDelivery]) {.gcsafe, raises: [].} =
  ## Resolve pending blocks
  ##

  for bd in blocksDelivery:
    p.blocks.withValue(bd.address, blockReq):
      if not blockReq.handle.finished:
        let
          startTime = blockReq.startTime
          stopTime = getMonoTime().ticks
          retrievalDurationUs = (stopTime - startTime) div 1000

        blockReq.handle.complete(bd.blk)

        codex_block_exchange_retrieval_time_us.set(retrievalDurationUs)

        if retrievalDurationUs > 500000:
          warn "High block retrieval time", retrievalDurationUs, address = bd.address
      else:
        trace "Block handle already finished", address = bd.address

proc setInFlight*(
  p: PendingBlocksManager,
  address: BlockAddress,
  inFlight = true) =
  ## Set inflight status for a block
  ##

  p.blocks.withValue(address, pending):
    pending[].inFlight = inFlight

proc isInFlight*(
  p: PendingBlocksManager,
  address: BlockAddress): bool =
  ## Check if a block is in flight
  ##

  p.blocks.withValue(address, pending):
    result = pending[].inFlight

proc contains*(p: PendingBlocksManager, cid: Cid): bool =
  BlockAddress.init(cid) in p.blocks

proc contains*(p: PendingBlocksManager, address: BlockAddress): bool =
  address in p.blocks

iterator wantList*(p: PendingBlocksManager): BlockAddress =
  for a in p.blocks.keys:
    yield a

iterator wantHandles*(p: PendingBlocksManager): Future[Block] =
  for v in p.blocks.values:
    yield v.handle

proc wantListLen*(p: PendingBlocksManager): int =
  p.blocks.len

func len*(p: PendingBlocksManager): int =
  p.blocks.len

func new*(T: type PendingBlocksManager): PendingBlocksManager =
  PendingBlocksManager()
