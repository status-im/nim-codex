## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/chronos
import pkg/libp2p/cid
import pkg/libp2p/multicodec
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ./pendingblocks

import ../protobuf/presence
import ../network
import ../peers

import ../../utils
import ../../discovery
import ../../stores/blockstore
import ../../logutils
import ../../manifest

logScope:
  topics = "codex discoveryengine"

declareGauge(codexInflightDiscovery, "inflight discovery requests")

const
  DefaultConcurrentDiscRequests = 10
  DefaultDiscoveryTimeout = 1.minutes
  DefaultMinPeersPerBlock = 3
  DefaultDiscoveryLoopSleep = 3.seconds

type
  DiscoveryEngine* = ref object of RootObj
    localStore*: BlockStore                                      # Local block store for this instance
    peers*: PeerCtxStore                                         # Peer context store
    network*: BlockExcNetwork                                    # Network interface
    discovery*: Discovery                                        # Discovery interface
    pendingBlocks*: PendingBlocksManager                         # Blocks we're awaiting to be resolved
    discEngineRunning*: bool                                     # Indicates if discovery is running
    concurrentDiscReqs: int                                      # Concurrent discovery requests
    discoveryLoop*: Future[void]                                 # Discovery loop task handle
    discoveryQueue*: AsyncQueue[Cid]                             # Discovery queue
    discoveryTasks*: seq[Future[void]]                           # Discovery tasks
    minPeersPerBlock*: int                                       # Max number of peers with block
    discoveryLoopSleep: Duration                                 # Discovery loop sleep
    inFlightDiscReqs*: Table[Cid, Future[seq[SignedPeerRecord]]] # Inflight discovery requests

proc discoveryQueueLoop(b: DiscoveryEngine) {.async.} =
  while b.discEngineRunning:
    for cid in toSeq(b.pendingBlocks.wantListBlockCids):
      try:
        await b.discoveryQueue.put(cid)
      except CancelledError:
        trace "Discovery loop cancelled"
        return
      except CatchableError as exc:
        warn "Exception in discovery loop", exc = exc.msg

    logScope:
      sleep = b.discoveryLoopSleep
      wanted = b.pendingBlocks.len

    await sleepAsync(b.discoveryLoopSleep)

proc discoveryTaskLoop(b: DiscoveryEngine) {.async.} =
  ## Run discovery tasks
  ##

  while b.discEngineRunning:
    try:
      let
        cid = await b.discoveryQueue.get()

      if cid in b.inFlightDiscReqs:
        trace "Discovery request already in progress", cid
        continue

      let
        haves = b.peers.peersHave(cid)

      if haves.len < b.minPeersPerBlock:
        try:
          let
            request = b.discovery
              .find(cid)
              .wait(DefaultDiscoveryTimeout)

          b.inFlightDiscReqs[cid] = request
          codexInflightDiscovery.set(b.inFlightDiscReqs.len.int64)
          let
            peers = await request

          let
            dialed = await allFinished(
              peers.mapIt( b.network.dialPeer(it.data) ))

          for i, f in dialed:
            if f.failed:
              await b.discovery.removeProvider(peers[i].data.peerId)

        finally:
          b.inFlightDiscReqs.del(cid)
          codexInflightDiscovery.set(b.inFlightDiscReqs.len.int64)
    except CancelledError:
      trace "Discovery task cancelled"
      return
    except CatchableError as exc:
      warn "Exception in discovery task runner", exc = exc.msg

  info "Exiting discovery task runner"

proc queueFindBlocksReq*(b: DiscoveryEngine, cids: seq[Cid]) {.inline.} =
  for cid in cids:
    if cid notin b.discoveryQueue:
      try:
        b.discoveryQueue.putNoWait(cid)
      except CatchableError as exc:
        warn "Exception queueing discovery request", exc = exc.msg

proc start*(b: DiscoveryEngine) {.async.} =
  ## Start the discengine task
  ##

  trace "Discovery engine start"

  if b.discEngineRunning:
    warn "Starting discovery engine twice"
    return

  b.discEngineRunning = true
  for i in 0..<b.concurrentDiscReqs:
    b.discoveryTasks.add(discoveryTaskLoop(b))

  b.discoveryLoop = discoveryQueueLoop(b)

proc stop*(b: DiscoveryEngine) {.async.} =
  ## Stop the discovery engine
  ##

  trace "Discovery engine stop"
  if not b.discEngineRunning:
    warn "Stopping discovery engine without starting it"
    return

  b.discEngineRunning = false
  for task in b.discoveryTasks:
    if not task.finished:
      trace "Awaiting discovery task to stop"
      await task.cancelAndWait()
      trace "Discovery task stopped"

  if not b.discoveryLoop.isNil and not b.discoveryLoop.finished:
    trace "Awaiting discovery loop to stop"
    await b.discoveryLoop.cancelAndWait()
    trace "Discovery loop stopped"

  trace "Discovery engine stopped"

proc new*(
    T: type DiscoveryEngine,
    localStore: BlockStore,
    peers: PeerCtxStore,
    network: BlockExcNetwork,
    discovery: Discovery,
    pendingBlocks: PendingBlocksManager,
    concurrentDiscReqs = DefaultConcurrentDiscRequests,
    discoveryLoopSleep = DefaultDiscoveryLoopSleep,
    minPeersPerBlock = DefaultMinPeersPerBlock
): DiscoveryEngine =
  ## Create a discovery engine instance for advertising services
  ##
  DiscoveryEngine(
    localStore: localStore,
    peers: peers,
    network: network,
    discovery: discovery,
    pendingBlocks: pendingBlocks,
    concurrentDiscReqs: concurrentDiscReqs,
    discoveryQueue: newAsyncQueue[Cid](concurrentDiscReqs),
    inFlightDiscReqs: initTable[Cid, Future[seq[SignedPeerRecord]]](),
    discoveryLoopSleep: discoveryLoopSleep,
    minPeersPerBlock: minPeersPerBlock)
