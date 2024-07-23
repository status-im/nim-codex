## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/libp2p/cid
import pkg/libp2p/multicodec
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ../protobuf/presence
import ../peers

import ../../utils
import ../../discovery
import ../../stores/blockstore
import ../../logutils
import ../../manifest

logScope:
  topics = "codex discoveryengine advertiser"

declareGauge(codexInflightAdvertise, "inflight advertise requests")

const
  DefaultConcurrentAdvertRequests = 10
  DefaultAdvertiseLoopSleep = 30.minutes

type
  Advertiser* = ref object of RootObj
    localStore*: BlockStore                                      # Local block store for this instance
    discovery*: Discovery                                        # Discovery interface

    advertiserRunning*: bool                                     # Indicates if discovery is running
    concurrentAdvReqs: int                                       # Concurrent advertise requests

    advertiseLoop*: Future[void]                                 # Advertise loop task handle
    advertiseQueue*: AsyncQueue[Cid]                             # Advertise queue
    advertiseTasks*: seq[Future[void]]                           # Advertise tasks

    advertiseLoopSleep: Duration                                 # Advertise loop sleep
    inFlightAdvReqs*: Table[Cid, Future[void]]                   # Inflight advertise requests

proc advertiseBlock(b: Advertiser, cid: Cid) {.async.} =
  without isM =? cid.isManifest, err:
    warn "Unable to determine if cid is manifest"
    return

  if isM:
    without blk =? await b.localStore.getBlock(cid), err:
      error "Error retrieving manifest block", cid, err = err.msg
      return

    without manifest =? Manifest.decode(blk), err:
      error "Unable to decode as manifest", err = err.msg
      return

    # announce manifest cid and tree cid
    await b.advertiseQueue.put(cid)
    await b.advertiseQueue.put(manifest.treeCid)
    trace "Advertising", blkCid = cid, treeCid = manifest.treeCid

proc advertiseQueueLoop(b: Advertiser) {.async.} =
  while b.advertiserRunning:
    if cids =? await b.localStore.listBlocks(blockType = BlockType.Manifest):
      trace "Advertiser begins iterating blocks..."
      for c in cids:
        if cid =? await c:
          await b.advertiseBlock(cid)
      trace "Advertiser iterating blocks finished."

    await sleepAsync(b.advertiseLoopSleep)

  info "Exiting advertise task loop"

proc advertiseTaskLoop(b: Advertiser) {.async.} =
  ## Run advertise tasks
  ##

  while b.advertiserRunning:
    try:
      let
        cid = await b.advertiseQueue.get()

      if cid in b.inFlightAdvReqs:
        continue

      try:
        let
          request = b.discovery.provide(cid)

        b.inFlightAdvReqs[cid] = request
        codexInflightAdvertise.set(b.inFlightAdvReqs.len.int64)
        await request

      finally:
        b.inFlightAdvReqs.del(cid)
        codexInflightAdvertise.set(b.inFlightAdvReqs.len.int64)
    except CancelledError:
      trace "Advertise task cancelled"
      return
    except CatchableError as exc:
      warn "Exception in advertise task runner", exc = exc.msg

  info "Exiting advertise task runner"

proc start*(b: Advertiser) {.async.} =
  ## Start the advertiser
  ##

  trace "Advertiser start"

  proc onBlock(cid: Cid) {.async.} = 
    await b.advertiseBlock(cid)

  b.localStore.setOnBlockStoredCallback(onBlock)

  if b.advertiserRunning:
    warn "Starting advertiser twice"
    return

  b.advertiserRunning = true
  for i in 0..<b.concurrentAdvReqs:
    b.advertiseTasks.add(advertiseTaskLoop(b))

  b.advertiseLoop = advertiseQueueLoop(b)

proc stop*(b: Advertiser) {.async.} =
  ## Stop the advertiser
  ##

  trace "Advertiser stop"
  if not b.advertiserRunning:
    warn "Stopping advertiser without starting it"
    return

  b.advertiserRunning = false
  for task in b.advertiseTasks:
    if not task.finished:
      trace "Awaiting advertise task to stop"
      await task.cancelAndWait()
      trace "Advertise task stopped"

  if not b.advertiseLoop.isNil and not b.advertiseLoop.finished:
    trace "Awaiting advertise loop to stop"
    await b.advertiseLoop.cancelAndWait()
    trace "Advertise loop stopped"

  trace "Advertiser stopped"

proc new*(
    T: type Advertiser,
    localStore: BlockStore,
    discovery: Discovery,
    concurrentAdvReqs = DefaultConcurrentAdvertRequests,
    advertiseLoopSleep = DefaultAdvertiseLoopSleep
): Advertiser =
  ## Create a advertiser instance
  ##
  Advertiser(
    localStore: localStore,
    discovery: discovery,
    concurrentAdvReqs: concurrentAdvReqs,
    advertiseQueue: newAsyncQueue[Cid](concurrentAdvReqs),
    inFlightAdvReqs: initTable[Cid, Future[void]](),
    advertiseLoopSleep: advertiseLoopSleep)
