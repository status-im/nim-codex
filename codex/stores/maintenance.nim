## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Store maintenance module
## Looks for and removes expired blocks from blockstores.

import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import ./repostore
import ../utils/timer
import ../utils/asynciter
import ../clock
import ../logutils
import ../systemclock

const
  DefaultBlockMaintenanceInterval* = 10.minutes
  DefaultNumberOfBlocksToMaintainPerInterval* = 1000

type
  BlockMaintainer* = ref object of RootObj
    repoStore: RepoStore
    interval: Duration
    timer: Timer
    clock: Clock
    numberOfBlocksPerInterval: int
    offset: int

proc new*(
    T: type BlockMaintainer,
    repoStore: RepoStore,
    interval: Duration,
    numberOfBlocksPerInterval = 100,
    timer = Timer.new(),
    clock: Clock = SystemClock.new()
): BlockMaintainer =
  ## Create new BlockMaintainer instance
  ##
  ## Call `start` to begin looking for for expired blocks
  ##
  BlockMaintainer(
    repoStore: repoStore,
    interval: interval,
    numberOfBlocksPerInterval: numberOfBlocksPerInterval,
    timer: timer,
    clock: clock,
    offset: 0)

proc deleteExpiredBlock(self: BlockMaintainer, cid: Cid): Future[void] {.async.} =
  if isErr (await self.repoStore.delBlock(cid)):
    trace "Unable to delete block from repoStore"

proc processBlockExpiration(self: BlockMaintainer, be: BlockExpiration): Future[void] {.async} =
  if be.expiry < self.clock.now:
    await self.deleteExpiredBlock(be.cid)
  else:
    inc self.offset

proc runBlockCheck(self: BlockMaintainer): Future[void] {.async.} =
  let expirations = await self.repoStore.getBlockExpirations(
    maxNumber = self.numberOfBlocksPerInterval,
    offset = self.offset
  )

  without iter =? expirations, err:
    trace "Unable to obtain blockExpirations iterator from repoStore"
    return

  var numberReceived = 0
  for beFut in iter:
    let be = await beFut
    inc numberReceived
    await self.processBlockExpiration(be)
    await sleepAsync(1.millis) # cooperative scheduling

  # If we received fewer blockExpirations from the iterator than we asked for,
  # We're at the end of the dataset and should start from 0 next time.
  if numberReceived < self.numberOfBlocksPerInterval:
    self.offset = 0

proc start*(self: BlockMaintainer) =
  proc onTimer(): Future[void] {.async.} =
    try:
      await self.runBlockCheck()
    except CancelledError as error:
      raise error
    except CatchableError as exc:
      error "Unexpected exception in BlockMaintainer.onTimer(): ", msg=exc.msg

  self.timer.start(onTimer, self.interval)

proc stop*(self: BlockMaintainer): Future[void] {.async.} =
  await self.timer.stop()
