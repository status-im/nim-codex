## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/chronos/futures
import pkg/datastore
import pkg/datastore/typedds
import pkg/libp2p/[cid, multicodec]
import pkg/questionable
import pkg/questionable/results

import ./coders
import ./types
import ./operations
import ../blockstore
import ../keyutils
import ../queryiterhelper
import ../../blocktype
import ../../clock
import ../../logutils
import ../../merkletree
import ../../utils

export blocktype, cid

logScope:
  topics = "codex repostore"

###########################################################
# BlockStore API
###########################################################

method getBlock*(self: RepoStore, cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the blockstore
  ##

  logScope:
    cid = cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return cid.emptyBlock

  without key =? makePrefixKey(self.postFixLen, cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  without data =? await self.repoDs.get(key), err:
    if not (err of DatastoreKeyNotFound):
      trace "Error getting block from datastore", err = err.msg, key
      return failure(err)

    return failure(newException(BlockNotFoundError, err.msg))

  trace "Got block for cid", cid
  return Block.new(cid, data, verify = true)

method getBlockAndProof*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!(Block, CodexProof)] {.async.} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  without blk =? await self.getBlock(leafMd.blkCid), err:
    return failure(err)

  success((blk, leafMd.proof))

method getBlock*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!Block] {.async.} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  await self.getBlock(leafMd.blkCid)

method getBlock*(self: RepoStore, address: BlockAddress): Future[?!Block] =
  ## Get a block from the blockstore
  ##

  if address.leaf:
    self.getBlock(address.treeCid, address.index)
  else:
    self.getBlock(address.cid)

method ensureExpiry*(
    self: RepoStore, cid: Cid, expiry: SecondsSince1970
): Future[?!void] {.async.} =
  ## Ensure that block's associated expiry is at least given timestamp
  ## If the current expiry is lower then it is updated to the given one, otherwise it is left intact
  ##

  if expiry <= 0:
    return
      failure(newException(ValueError, "Expiry timestamp must be larger then zero"))

  await self.updateBlockMetadata(cid, minExpiry = expiry)

method ensureExpiry*(
    self: RepoStore, treeCid: Cid, index: Natural, expiry: SecondsSince1970
): Future[?!void] {.async.} =
  ## Ensure that block's associated expiry is at least given timestamp
  ## If the current expiry is lower then it is updated to the given one, otherwise it is left intact
  ##

  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  await self.ensureExpiry(leafMd.blkCid, expiry)

method putCidAndProof*(
    self: RepoStore, treeCid: Cid, index: Natural, blkCid: Cid, proof: CodexProof
): Future[?!void] {.async.} =
  ## Put a block to the blockstore
  ##

  logScope:
    treeCid = treeCid
    index = index
    blkCid = blkCid

  trace "Storing LeafMetadata"

  without res =? await self.putLeafMetadata(treeCid, index, blkCid, proof), err:
    return failure(err)

  if blkCid.mcodec == BlockCodec:
    if res == Stored:
      if err =? (await self.updateBlockMetadata(blkCid, plusRefCount = 1)).errorOption:
        return failure(err)
      trace "Leaf metadata stored, block refCount incremented"
    else:
      trace "Leaf metadata already exists"

  return success()

method getCidAndProof*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!(Cid, CodexProof)] {.async.} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  success((leafMd.blkCid, leafMd.proof))

method getCid*(self: RepoStore, treeCid: Cid, index: Natural): Future[?!Cid] {.async.} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  success(leafMd.blkCid)

method putBlock*(
    self: RepoStore, blk: Block, ttl = Duration.none
): Future[?!void] {.async.} =
  ## Put a block to the blockstore
  ##

  logScope:
    cid = blk.cid

  let expiry = self.clock.now() + (ttl |? self.blockTtl).seconds

  without res =? await self.storeBlock(blk, expiry), err:
    return failure(err)

  if res.kind == Stored:
    trace "Block Stored"
    if err =? (await self.updateQuotaUsage(plusUsed = res.used)).errorOption:
      # rollback changes
      without delRes =? await self.tryDeleteBlock(blk.cid), err:
        return failure(err)
      return failure(err)

    if err =? (await self.updateTotalBlocksCount(plusCount = 1)).errorOption:
      return failure(err)

    if onBlock =? self.onBlockStored:
      await onBlock(blk.cid)
  else:
    trace "Block already exists"

  return success()

method delBlock*(self: RepoStore, cid: Cid): Future[?!void] {.async.} =
  ## Delete a block from the blockstore when block refCount is 0 or block is expired
  ##

  logScope:
    cid = cid

  trace "Attempting to delete a block"

  without res =? await self.tryDeleteBlock(cid, self.clock.now()), err:
    return failure(err)

  if res.kind == Deleted:
    trace "Block deleted"
    if err =? (await self.updateTotalBlocksCount(minusCount = 1)).errorOption:
      return failure(err)

    if err =? (await self.updateQuotaUsage(minusUsed = res.released)).errorOption:
      return failure(err)
  elif res.kind == InUse:
    trace "Block in use, refCount > 0 and not expired"
  else:
    trace "Block not found in store"

  return success()

method delBlock*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!void] {.async.} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    if err of BlockNotFoundError:
      return success()
    else:
      return failure(err)

  if err =?
      (await self.updateBlockMetadata(leafMd.blkCid, minusRefCount = 1)).errorOption:
    if not (err of BlockNotFoundError):
      return failure(err)

  await self.delBlock(leafMd.blkCid) # safe delete, only if refCount == 0

method hasBlock*(self: RepoStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  logScope:
    cid = cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success true

  without key =? makePrefixKey(self.postFixLen, cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  return await self.repoDs.has(key)

method hasBlock*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!bool] {.async.} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    if err of BlockNotFoundError:
      return success(false)
    else:
      return failure(err)

  await self.hasBlock(leafMd.blkCid)

method listBlocks*(
    self: RepoStore, blockType = BlockType.Manifest
): Future[?!AsyncIter[?Cid]] {.async.} =
  ## Get the list of blocks in the RepoStore.
  ## This is an intensive operation
  ##

  var iter = AsyncIter[?Cid]()

  let key =
    case blockType
    of BlockType.Manifest: CodexManifestKey
    of BlockType.Block: CodexBlocksKey
    of BlockType.Both: CodexRepoKey

  let query = Query.init(key, value = false)
  without queryIter =? (await self.repoDs.query(query)), err:
    trace "Error querying cids in repo", blockType, err = err.msg
    return failure(err)

  proc next(): Future[?Cid] {.async.} =
    await idleAsync()
    if queryIter.finished:
      iter.finish
    else:
      if pair =? (await queryIter.next()) and cid =? pair.key:
        doAssert pair.data.len == 0
        trace "Retrieved record from repo", cid
        return Cid.init(cid.value).option
      else:
        return Cid.none

  iter.next = next
  return success iter

proc createBlockExpirationQuery(maxNumber: int, offset: int): ?!Query =
  let queryKey = ?createBlockExpirationMetadataQueryKey()
  success Query.init(queryKey, offset = offset, limit = maxNumber)

method getBlockExpirations*(
    self: RepoStore, maxNumber: int, offset: int
): Future[?!AsyncIter[BlockExpiration]] {.async, base.} =
  ## Get iterator with block expirations
  ##

  without beQuery =? createBlockExpirationQuery(maxNumber, offset), err:
    error "Unable to format block expirations query", err = err.msg
    return failure(err)

  without queryIter =? await query[BlockMetadata](self.metaDs, beQuery), err:
    error "Unable to execute block expirations query", err = err.msg
    return failure(err)

  without asyncQueryIter =? await queryIter.toAsyncIter(), err:
    error "Unable to convert QueryIter to AsyncIter", err = err.msg
    return failure(err)

  let filteredIter: AsyncIter[KeyVal[BlockMetadata]] =
    await asyncQueryIter.filterSuccess()

  proc mapping(kv: KeyVal[BlockMetadata]): Future[?BlockExpiration] {.async.} =
    without cid =? Cid.init(kv.key.value).mapFailure, err:
      error "Failed decoding cid", err = err.msg
      return BlockExpiration.none

    BlockExpiration(cid: cid, expiry: kv.value.expiry).some

  let blockExpIter =
    await mapFilter[KeyVal[BlockMetadata], BlockExpiration](filteredIter, mapping)

  success(blockExpIter)

method close*(self: RepoStore): Future[void] {.async.} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  trace "Closing repostore"

  if not self.metaDs.isNil:
    (await self.metaDs.close()).expect("Should meta datastore")

  if not self.repoDs.isNil:
    (await self.repoDs.close()).expect("Should repo datastore")

###########################################################
# RepoStore procs
###########################################################

proc reserve*(self: RepoStore, bytes: NBytes): Future[?!void] {.async.} =
  ## Reserve bytes
  ##

  trace "Reserving bytes", bytes

  await self.updateQuotaUsage(plusReserved = bytes)

proc release*(self: RepoStore, bytes: NBytes): Future[?!void] {.async.} =
  ## Release bytes
  ##

  trace "Releasing bytes", bytes

  await self.updateQuotaUsage(minusReserved = bytes)

proc start*(self: RepoStore): Future[void] {.async.} =
  ## Start repo
  ##

  if self.started:
    trace "Repo already started"
    return

  trace "Starting rep"
  if err =? (await self.updateTotalBlocksCount()).errorOption:
    raise newException(CodexError, err.msg)

  if err =? (await self.updateQuotaUsage()).errorOption:
    raise newException(CodexError, err.msg)

  self.started = true

proc stop*(self: RepoStore): Future[void] {.async.} =
  ## Stop repo
  ##
  if not self.started:
    trace "Repo is not started"
    return

  trace "Stopping repo"
  await self.close()

  self.started = false
