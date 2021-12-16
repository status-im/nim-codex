## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/os

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/stew/io2

import ./memorystore
import ./blockstore
import ../blocktype

export blockstore

logScope:
  topics = "dagger localstore"

type
  LocalStore* = ref object of BlockStore
    cache: BlockStore
    repoDir: string
    prefixLen*: int

template blockPath(self: LocalStore, cid: Cid): string =
  self.repoDir / ($cid)[0..<self.prefixLen]

proc contains*(s: LocalStore, cid: Cid): bool =
  s.hasBlock(cid)

method getBlock*(
  self: LocalStore,
  cid: Cid): Future[?Block] {.async.} =
  ## Get a block from the stores
  ##

  if cid notin self:
    return Block.none

  var data: seq[byte]
  let path = self.blockPath(cid) / $cid
  if (
    let res = io2.readFile(path, data);
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Cannot read file", path , error
    return Block.none

  return Block.new(cid, data).some

method putBlock*(
  self: LocalStore,
  blk: Block): Future[bool] {.async.} =
  ## Put a block to the blockstore
  ##

  if blk.cid in self:
    return

  # if directory exists it wont fail
  if io2.createPath(self.blockPath(blk.cid)).isErr:
    trace "Unable to create block prefix dir", dir = self.blockPath(blk.cid)
    return false

  let path = self.blockPath(blk.cid) / $blk.cid
  if (
    let res = io2.writeFile(path, blk.data);
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Unable to store block", path, cid = blk.cid, error
    return false

  return true

method delBlock*(
  self: LocalStore,
  cid: Cid): Future[bool] {.async.} =
  ## Delete a block/s from the block store
  ##

  let path = self.blockPath(cid)
  if (
    let res = io2.removeFile(path);
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Unable to delete block", path, cid, error
    return false

  return true

{.pop.}

method hasBlock*(self: LocalStore, cid: Cid): bool =
  ## Check if the block exists in the blockstore
  ##

  isFile(self.blockPath(cid) / $cid)

proc new*(
  T: type LocalStore,
  repoDir: string,
  prefixLen: int = 2,
  cache: BlockStore = MemoryStore.new()): T =
  T(
    prefixLen: prefixLen,
    repoDir: repoDir,
    cache: cache)
