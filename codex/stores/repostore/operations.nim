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
import pkg/libp2p/cid
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ./coders
import ./types
import ../blockstore
import ../keyutils
import ../../blocktype
import ../../clock
import ../../logutils
import ../../merkletree

logScope:
  topics = "codex repostore"

declareGauge(codex_repostore_blocks, "codex repostore blocks")
declareGauge(codex_repostore_bytes_used, "codex repostore bytes used")
declareGauge(codex_repostore_bytes_reserved, "codex repostore bytes reserved")

proc putLeafMetadata*(
    self: RepoStore, treeCid: Cid, index: Natural, blkCid: Cid, proof: CodexProof
): Future[?!StoreResultKind] {.async.} =
  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  await self.metaDs.modifyGet(
    key,
    proc(
        maybeCurrMd: ?LeafMetadata
    ): Future[(?LeafMetadata, StoreResultKind)] {.async.} =
      var
        md: LeafMetadata
        res: StoreResultKind

      if currMd =? maybeCurrMd:
        md = currMd
        res = AlreadyInStore
      else:
        md = LeafMetadata(blkCid: blkCid, proof: proof)
        res = Stored

      (md.some, res),
  )

proc getLeafMetadata*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!LeafMetadata] {.async.} =
  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  without leafMd =? await get[LeafMetadata](self.metaDs, key), err:
    if err of DatastoreKeyNotFound:
      return failure(newException(BlockNotFoundError, err.msg))
    else:
      return failure(err)

  success(leafMd)

proc updateTotalBlocksCount*(
    self: RepoStore, plusCount: Natural = 0, minusCount: Natural = 0
): Future[?!void] {.async.} =
  await self.metaDs.modify(
    CodexTotalBlocksKey,
    proc(maybeCurrCount: ?Natural): Future[?Natural] {.async.} =
      let count: Natural =
        if currCount =? maybeCurrCount:
          currCount + plusCount - minusCount
        else:
          plusCount - minusCount

      self.totalBlocks = count
      codex_repostore_blocks.set(count.int64)
      count.some,
  )

proc updateQuotaUsage*(
    self: RepoStore,
    plusUsed: NBytes = 0.NBytes,
    minusUsed: NBytes = 0.NBytes,
    plusReserved: NBytes = 0.NBytes,
    minusReserved: NBytes = 0.NBytes,
): Future[?!void] {.async.} =
  await self.metaDs.modify(
    QuotaUsedKey,
    proc(maybeCurrUsage: ?QuotaUsage): Future[?QuotaUsage] {.async.} =
      var usage: QuotaUsage

      if currUsage =? maybeCurrUsage:
        usage = QuotaUsage(
          used: currUsage.used + plusUsed - minusUsed,
          reserved: currUsage.reserved + plusReserved - minusReserved,
        )
      else:
        usage =
          QuotaUsage(used: plusUsed - minusUsed, reserved: plusReserved - minusReserved)

      if usage.used + usage.reserved > self.quotaMaxBytes:
        raise newException(
          QuotaNotEnoughError,
          "Quota usage would exceed the limit. Used: " & $usage.used & ", reserved: " &
            $usage.reserved & ", limit: " & $self.quotaMaxBytes,
        )
      else:
        self.quotaUsage = usage
        codex_repostore_bytes_used.set(usage.used.int64)
        codex_repostore_bytes_reserved.set(usage.reserved.int64)
        return usage.some,
  )

proc updateBlockMetadata*(
    self: RepoStore,
    cid: Cid,
    plusRefCount: Natural = 0,
    minusRefCount: Natural = 0,
    minExpiry: SecondsSince1970 = 0,
): Future[?!void] {.async.} =
  if cid.isEmpty:
    return success()

  without metaKey =? createBlockExpirationMetadataKey(cid), err:
    return failure(err)

  await self.metaDs.modify(
    metaKey,
    proc(maybeCurrBlockMd: ?BlockMetadata): Future[?BlockMetadata] {.async.} =
      if currBlockMd =? maybeCurrBlockMd:
        BlockMetadata(
          size: currBlockMd.size,
          expiry: max(currBlockMd.expiry, minExpiry),
          refCount: currBlockMd.refCount + plusRefCount - minusRefCount,
        ).some
      else:
        raise newException(
          BlockNotFoundError, "Metadata for block with cid " & $cid & " not found"
        ),
  )

proc storeBlock*(
    self: RepoStore, blk: Block, minExpiry: SecondsSince1970
): Future[?!StoreResult] {.async.} =
  if blk.isEmpty:
    return success(StoreResult(kind: AlreadyInStore))

  without metaKey =? createBlockExpirationMetadataKey(blk.cid), err:
    return failure(err)

  without blkKey =? makePrefixKey(self.postFixLen, blk.cid), err:
    return failure(err)

  await self.metaDs.modifyGet(
    metaKey,
    proc(maybeCurrMd: ?BlockMetadata): Future[(?BlockMetadata, StoreResult)] {.async.} =
      var
        md: BlockMetadata
        res: StoreResult

      if currMd =? maybeCurrMd:
        if currMd.size == blk.data.len.NBytes:
          md = BlockMetadata(
            size: currMd.size,
            expiry: max(currMd.expiry, minExpiry),
            refCount: currMd.refCount,
          )
          res = StoreResult(kind: AlreadyInStore)

          # making sure that the block acutally is stored in the repoDs
          without hasBlock =? await self.repoDs.has(blkKey), err:
            raise err

          if not hasBlock:
            warn "Block metadata is present, but block is absent. Restoring block.",
              cid = blk.cid
            if err =? (await self.repoDs.put(blkKey, blk.data)).errorOption:
              raise err
        else:
          raise newException(
            CatchableError,
            "Repo already stores a block with the same cid but with a different size, cid: " &
              $blk.cid,
          )
      else:
        md = BlockMetadata(size: blk.data.len.NBytes, expiry: minExpiry, refCount: 0)
        res = StoreResult(kind: Stored, used: blk.data.len.NBytes)
        if err =? (await self.repoDs.put(blkKey, blk.data)).errorOption:
          raise err

      (md.some, res),
  )

proc tryDeleteBlock*(
    self: RepoStore, cid: Cid, expiryLimit = SecondsSince1970.low
): Future[?!DeleteResult] {.async.} =
  if cid.isEmpty:
    return success(DeleteResult(kind: InUse))

  without metaKey =? createBlockExpirationMetadataKey(cid), err:
    return failure(err)

  without blkKey =? makePrefixKey(self.postFixLen, cid), err:
    return failure(err)

  await self.metaDs.modifyGet(
    metaKey,
    proc(
        maybeCurrMd: ?BlockMetadata
    ): Future[(?BlockMetadata, DeleteResult)] {.async.} =
      var
        maybeMeta: ?BlockMetadata
        res: DeleteResult

      if currMd =? maybeCurrMd:
        if currMd.refCount == 0 or currMd.expiry < expiryLimit:
          maybeMeta = BlockMetadata.none
          res = DeleteResult(kind: Deleted, released: currMd.size)

          if err =? (await self.repoDs.delete(blkKey)).errorOption:
            raise err
        else:
          maybeMeta = currMd.some
          res = DeleteResult(kind: InUse)
      else:
        maybeMeta = BlockMetadata.none
        res = DeleteResult(kind: NotFound)

        # making sure that the block acutally is removed from the repoDs
        without hasBlock =? await self.repoDs.has(blkKey), err:
          raise err

        if hasBlock:
          warn "Block metadata is absent, but block is present. Removing block.", cid
          if err =? (await self.repoDs.delete(blkKey)).errorOption:
            raise err

      (maybeMeta, res),
  )
