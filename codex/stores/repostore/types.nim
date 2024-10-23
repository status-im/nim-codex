## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/datastore
import pkg/datastore/typedds
import pkg/libp2p/cid
import pkg/questionable

import ../blockstore
import ../../clock
import ../../errors
import ../../merkletree
import ../../systemclock
import ../../units

const
  DefaultBlockTtl* = 24.hours
  DefaultQuotaBytes* = 8.GiBs

type
  QuotaNotEnoughError* = object of CodexError

  RepoStore* = ref object of BlockStore
    postFixLen*: int
    repoDs*: Datastore
    metaDs*: TypedDatastore
    clock*: Clock
    quotaMaxBytes*: NBytes
    quotaUsage*: QuotaUsage
    totalBlocks*: Natural
    blockTtl*: Duration
    started*: bool

  QuotaUsage* {.serialize.} = object
    used*: NBytes
    reserved*: NBytes

  BlockMetadata* {.serialize.} = object
    expiry*: SecondsSince1970
    size*: NBytes
    refCount*: Natural

  LeafMetadata* {.serialize.} = object
    blkCid*: Cid
    proof*: CodexProof

  BlockExpiration* {.serialize.} = object
    cid*: Cid
    expiry*: SecondsSince1970

  DeleteResultKind* {.serialize.} = enum
    Deleted = 0,    # block removed from store
    InUse = 1,      # block not removed, refCount > 0 and not expired
    NotFound = 2    # block not found in store

  DeleteResult* {.serialize.} = object
    kind*: DeleteResultKind
    released*: NBytes

  StoreResultKind* {.serialize.} = enum
    Stored = 0,         # new block stored
    AlreadyInStore = 1  # block already in store

  StoreResult* {.serialize.} = object
    kind*: StoreResultKind
    used*: NBytes

func quotaUsedBytes*(self: RepoStore): NBytes =
  self.quotaUsage.used

func quotaReservedBytes*(self: RepoStore): NBytes =
  self.quotaUsage.reserved

func totalUsed*(self: RepoStore): NBytes =
  (self.quotaUsedBytes + self.quotaReservedBytes)

func available*(self: RepoStore): NBytes =
  return self.quotaMaxBytes - self.totalUsed

func available*(self: RepoStore, bytes: NBytes): bool =
  return bytes < self.available()

func new*(
    T: type RepoStore,
    repoDs: Datastore,
    metaDs: Datastore,
    clock: Clock = SystemClock.new(),
    postFixLen = 2,
    quotaMaxBytes = DefaultQuotaBytes,
    blockTtl = DefaultBlockTtl
): RepoStore =
  ## Create new instance of a RepoStore
  ##
  RepoStore(
    repoDs: repoDs,
    metaDs: TypedDatastore.init(metaDs),
    clock: clock,
    postFixLen: postFixLen,
    quotaMaxBytes: quotaMaxBytes,
    blockTtl: blockTtl,
    onBlockStored: CidCallback.none
  )
