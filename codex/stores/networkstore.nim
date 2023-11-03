## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}

import std/sugar

import pkg/chronicles
import pkg/chronos
import pkg/libp2p

import ../blocktype
import ../utils/asyncheapqueue
import ../utils/asynciter

import ./blockstore
import ../blockexchange
import ../merkletree
import ../blocktype

export blockstore, blockexchange, asyncheapqueue

logScope:
  topics = "codex networkstore"

const BlockPrefetchAmount = 5

type
  NetworkStore* = ref object of BlockStore
    engine*: BlockExcEngine # blockexc decision engine
    localStore*: BlockStore # local block store

method getBlock*(self: NetworkStore, address: BlockAddress): Future[?!Block] {.async.} =
  trace "Getting block from local store or network", address

  without blk =? await self.localStore.getBlock(address), error:
    if not (error of BlockNotFoundError): return failure error
    trace "Block not in local store", address

    without newBlock =? (await self.engine.requestBlock(address)).catch, error:
      trace "Unable to get block from exchange engine", address
      return failure error

    return success newBlock

  return success blk

method getBlock*(self: NetworkStore, cid: Cid): Future[?!Block] =
  ## Get a block from the blockstore
  ##

  self.getBlock(BlockAddress.init(cid))

method getBlock*(self: NetworkStore, treeCid: Cid, index: Natural): Future[?!Block] =
  ## Get a block from the blockstore
  ##

  self.getBlock(BlockAddress.init(treeCid, index))

method putBlock*(
    self: NetworkStore,
    blk: Block,
    ttl = Duration.none
): Future[?!void] {.async.} =
  ## Store block locally and notify the network
  ##

  trace "Puting block into network store", cid = blk.cid

  let res = await self.localStore.putBlock(blk, ttl)
  if res.isErr:
    return res

  await self.engine.resolveBlocks(@[blk])
  return success()

method putBlockCidAndProof*(
  self: NetworkStore,
  treeCid: Cid,
  index: Natural,
  blockCid: Cid,
  proof: MerkleProof
): Future[?!void] =
  self.localStore.putBlockCidAndProof(treeCid, index, blockCid, proof)

method delBlock*(self: NetworkStore, cid: Cid): Future[?!void] =
  ## Delete a block from the blockstore
  ##

  trace "Deleting block from network store", cid
  return self.localStore.delBlock(cid)

{.pop.}

method hasBlock*(self: NetworkStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  trace "Checking network store for block existence", cid
  return await self.localStore.hasBlock(cid)

method close*(self: NetworkStore): Future[void] {.async.} =
  ## Close the underlying local blockstore
  ##

  if not self.localStore.isNil:
    await self.localStore.close

proc new*(
  T: type NetworkStore,
  engine: BlockExcEngine,
  localStore: BlockStore
): NetworkStore =
  ## Create new instance of a NetworkStore
  ##
  NetworkStore(
      localStore: localStore,
      engine: engine)
