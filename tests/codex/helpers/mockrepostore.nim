## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import pkg/codex/stores/repostore
import pkg/codex/utils/asynciter

type MockRepoStore* = ref object of RepoStore
  delBlockCids*: seq[Cid]
  getBeMaxNumber*: int
  getBeOffset*: int

  testBlockExpirations*: seq[BlockExpiration]
  getBlockExpirationsThrows*: bool

method delBlock*(self: MockRepoStore, cid: Cid): Future[?!void] {.async.} =
  self.delBlockCids.add(cid)
  self.testBlockExpirations = self.testBlockExpirations.filterIt(it.cid != cid)
  return success()

method getBlockExpirations*(
    self: MockRepoStore, maxNumber: int, offset: int
): Future[?!AsyncIter[BlockExpiration]] {.async.} =
  if self.getBlockExpirationsThrows:
    raise new CatchableError

  self.getBeMaxNumber = maxNumber
  self.getBeOffset = offset

  let
    testBlockExpirationsCpy = @(self.testBlockExpirations)
    limit = min(offset + maxNumber, len(testBlockExpirationsCpy))

  let
    iter1 = AsyncIter[int].new(offset ..< limit)
    iter2 = map[int, BlockExpiration](
      iter1,
      proc(i: int): Future[BlockExpiration] {.async.} =
        testBlockExpirationsCpy[i],
    )

  success(iter2)
