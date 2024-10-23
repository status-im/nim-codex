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

import std/options

import pkg/chronos
import pkg/libp2p
import pkg/lrucache
import pkg/questionable
import pkg/questionable/results

import ./blockstore
import ../units
import ../chunker
import ../errors
import ../logutils
import ../manifest
import ../merkletree
import ../utils
import ../clock

export blockstore

logScope:
  topics = "codex cachestore"

type
  CacheStore* = ref object of BlockStore
    currentSize*: NBytes
    size*: NBytes
    cache: LruCache[Cid, Block]
    cidAndProofCache: LruCache[(Cid, Natural), (Cid, CodexProof)]

  InvalidBlockSize* = object of CodexError

const
  DefaultCacheSize*: NBytes = 5.MiBs

method getBlock*(self: CacheStore, cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the stores
  ##

  trace "Getting block from cache", cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return cid.emptyBlock

  if cid notin self.cache:
    return failure (ref BlockNotFoundError)(msg: "Block not in cache " & $cid)

  try:
    return success self.cache[cid]
  except CancelledError as error:
    raise error
  except CatchableError as exc:
    trace "Error requesting block from cache", cid, error = exc.msg
    return failure exc

method getCidAndProof*(
  self: CacheStore,
  treeCid: Cid,
  index: Natural): Future[?!(Cid, CodexProof)] {.async.} =

  if cidAndProof =? self.cidAndProofCache.getOption((treeCid, index)):
    success(cidAndProof)
  else:
    failure(newException(BlockNotFoundError, "Block not in cache: " & $BlockAddress.init(treeCid, index)))

method getBlock*(self: CacheStore, treeCid: Cid, index: Natural): Future[?!Block] {.async.} =
  without cidAndProof =? (await self.getCidAndProof(treeCid, index)), err:
    return failure(err)

  await self.getBlock(cidAndProof[0])

method getBlockAndProof*(self: CacheStore, treeCid: Cid, index: Natural): Future[?!(Block, CodexProof)] {.async.} =
  without cidAndProof =? (await self.getCidAndProof(treeCid, index)), err:
    return failure(err)

  let (cid, proof) = cidAndProof

  without blk =? await self.getBlock(cid), err:
    return failure(err)

  success((blk, proof))

method getBlock*(self: CacheStore, address: BlockAddress): Future[?!Block] =
  if address.leaf:
    self.getBlock(address.treeCid, address.index)
  else:
    self.getBlock(address.cid)

method hasBlock*(self: CacheStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  trace "Checking CacheStore for block presence", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true.success

  return (cid in self.cache).success

method hasBlock*(self: CacheStore, treeCid: Cid, index: Natural): Future[?!bool] {.async.} =
  without cidAndProof =? (await self.getCidAndProof(treeCid, index)), err:
    if err of BlockNotFoundError:
      return success(false)
    else:
      return failure(err)

  await self.hasBlock(cidAndProof[0])

func cids(self: CacheStore): (iterator: Cid {.gcsafe.}) =
  return iterator(): Cid =
    for cid in self.cache.keys:
      yield cid

method listBlocks*(
    self: CacheStore,
    blockType = BlockType.Manifest
): Future[?!AsyncIter[?Cid]] {.async.} =
  ## Get the list of blocks in the BlockStore. This is an intensive operation
  ##

  let
    cids = self.cids()

  proc isFinished(): bool =
    return finished(cids)

  proc genNext(): Future[Cid] {.async.} =
    cids()

  let iter = await (AsyncIter[Cid].new(genNext, isFinished)
    .filter(
      proc (cid: Cid): Future[bool] {.async.} =
        without isManifest =? cid.isManifest, err:
          trace "Error checking if cid is a manifest", err = err.msg
          return false

        case blockType:
        of BlockType.Both:
          return true
        of BlockType.Manifest:
          return isManifest
        of BlockType.Block:
          return not isManifest
    ))

  return success(map[Cid, ?Cid](iter,
      proc (cid: Cid): Future[?Cid] {.async.} =
        some(cid)
  ))

func putBlockSync(self: CacheStore, blk: Block): bool =

  let blkSize = blk.data.len.NBytes # in bytes

  if blkSize > self.size:
    trace "Block size is larger than cache size", blk = blkSize, cache = self.size
    return false

  while self.currentSize + blkSize > self.size:
    try:
      let removed = self.cache.removeLru()
      self.currentSize -= removed.data.len.NBytes
    except EmptyLruCacheError as exc:
      # if the cache is empty, can't remove anything, so break and add item
      # to the cache
      trace "Exception puting block to cache", exc = exc.msg
      break

  self.cache[blk.cid] = blk
  self.currentSize += blkSize
  return true

method putBlock*(
  self: CacheStore,
  blk: Block,
  ttl = Duration.none): Future[?!void] {.async.} =
  ## Put a block to the blockstore
  ##

  trace "Storing block in cache", cid = blk.cid
  if blk.isEmpty:
    trace "Empty block, ignoring"
    return success()

  discard self.putBlockSync(blk)
  if onBlock =? self.onBlockStored:
    await onBlock(blk.cid)
    
  return success()

method putCidAndProof*(
  self: CacheStore,
  treeCid: Cid,
  index: Natural,
  blockCid: Cid,
  proof: CodexProof
): Future[?!void] {.async.} =
  self.cidAndProofCache[(treeCid, index)] = (blockCid, proof)
  success()

method ensureExpiry*(
    self: CacheStore,
    cid: Cid,
    expiry: SecondsSince1970
): Future[?!void] {.async.} =
  ## Updates block's assosicated TTL in store - not applicable for CacheStore
  ##

  discard # CacheStore does not have notion of TTL

method ensureExpiry*(
    self: CacheStore,
    treeCid: Cid,
    index: Natural,
    expiry: SecondsSince1970
): Future[?!void] {.async.} =
  ## Updates block's associated TTL in store - not applicable for CacheStore
  ##

  discard # CacheStore does not have notion of TTL

method delBlock*(self: CacheStore, cid: Cid): Future[?!void] {.async.} =
  ## Delete a block from the blockstore
  ##

  trace "Deleting block from cache", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success()

  let removed = self.cache.del(cid)
  if removed.isSome:
    self.currentSize -= removed.get.data.len.NBytes

  return success()

method delBlock*(self: CacheStore, treeCid: Cid, index: Natural): Future[?!void] {.async.} =
  let maybeRemoved = self.cidAndProofCache.del((treeCid, index))

  if removed =? maybeRemoved:
    return await self.delBlock(removed[0])

  return success()

method close*(self: CacheStore): Future[void] {.async.} =
  ## Close the blockstore, a no-op for this implementation
  ##

  discard

proc new*(
    _: type CacheStore,
    blocks: openArray[Block] = [],
    cacheSize: NBytes = DefaultCacheSize,
    chunkSize: NBytes = DefaultChunkSize
): CacheStore {.raises: [Defect, ValueError].} =
  ## Create a new CacheStore instance
  ##
  ## `cacheSize` and `chunkSize` are both in bytes
  ##

  if cacheSize < chunkSize:
    raise newException(ValueError, "cacheSize cannot be less than chunkSize")

  let
    currentSize = 0'nb
    size = int(cacheSize div chunkSize)
    cache = newLruCache[Cid, Block](size)
    cidAndProofCache = newLruCache[(Cid, Natural), (Cid, CodexProof)](size)
    store = CacheStore(
      cache: cache,
      cidAndProofCache: cidAndProofCache,
      currentSize: currentSize,
      size: cacheSize,
      onBlockStored: CidCallback.none)

  for blk in blocks:
    discard store.putBlockSync(blk)

  return store

proc new*(
    _: type CacheStore,
    blocks: openArray[Block] = [],
    cacheSize: int,
    chunkSize: int
): CacheStore {.raises: [Defect, ValueError].} =
  CacheStore.new(blocks, NBytes cacheSize, NBytes chunkSize)
