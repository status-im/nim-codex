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

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ../blocktype
import ../merkletree
import ../utils

export blocktype

type
  BlockNotFoundError* = object of CodexError

  BlockType* {.pure.} = enum
    Manifest, Block, Both

  BlockStore* = ref object of RootObj

method getBlock*(self: BlockStore, cid: Cid): Future[?!Block] {.base.} =
  ## Get a block from the blockstore
  ##

  raiseAssert("Not implemented!")

method getTree*(self: BlockStore, treeCid: Cid): Future[?!MerkleTree] {.base.} =
  ## Get a merkle tree by Cid
  ## 
  
  raiseAssert("Not implemented!")

method getBlock*(self: BlockStore, treeCid: Cid, index: Natural, merkleRoot: MultiHash): Future[?!Block] {.base.} =
  ## Get a block by Cid of a merkle tree and an index of a leaf in a tree, validate inclusion using merkle root
  ## 
  
  raiseAssert("Not implemented!")

method getBlockAndProof*(self: BlockStore, treeCid: Cid, index: Natural): Future[?!(Block, MerkleProof)] {.base.} =
  ## Get a block and associated inclusion proof by Cid of a merkle tree and an index of a leaf in a tree
  ## 
  
  raiseAssert("Not implemented!")

method getBlocks*(self: BlockStore, treeCid: Cid, leavesCount: Natural, merkleRoot: MultiHash): Future[?!AsyncIter[?!Block]] {.base.} =
  ## Get all blocks in range [0..<leavesCount] by Cid of a merkle tree, validate inclusion using merkle root
  ## 

  raiseAssert("Not implemented!")

method putBlock*(
    self: BlockStore,
    blk: Block,
    ttl = Duration.none
): Future[?!void] {.base.} =
  ## Put a block to the blockstore
  ##

  raiseAssert("Not implemented!")

method delBlock*(self: BlockStore, cid: Cid): Future[?!void] {.base.} =
  ## Delete a block from the blockstore
  ##

  raiseAssert("Not implemented!")

method delBlock*(self: BlockStore, treeCid: Cid, index: Natural): Future[?!void] {.base.} =
  ## Delete a block from the blockstore
  ##

  raiseAssert("Not implemented!")

method hasBlock*(self: BlockStore, cid: Cid): Future[?!bool] {.base.} =
  ## Check if the block exists in the blockstore
  ##

  raiseAssert("Not implemented!")

method hasBlock*(self: BlockStore, tree: Cid, index: Natural): Future[?!bool] {.base.} =
  ## Check if the block exists in the blockstore
  ##

  raiseAssert("Not implemented!")

method listBlocks*(
  self: BlockStore,
  blockType = BlockType.Manifest): Future[?!AsyncIter[?Cid]] {.base.} =
  ## Get the list of blocks in the BlockStore. This is an intensive operation
  ##

  raiseAssert("Not implemented!")

method close*(self: BlockStore): Future[void] {.base.} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  raiseAssert("Not implemented!")

proc contains*(self: BlockStore, blk: Cid): Future[bool] {.async.} =
  ## Check if the block exists in the blockstore.
  ## Return false if error encountered
  ##

  return (await self.hasBlock(blk)) |? false

proc contains*(self: BlockStore, address: BlockAddress): Future[bool] {.async.} =
  return if address.leaf:
    (await self.hasBlock(address.treeCid, address.index)) |? false
    else:
    (await self.hasBlock(address.cid)) |? false
