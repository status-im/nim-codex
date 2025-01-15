import std/sequtils
import std/tables

import pkg/chronos

import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/blockexchange/engine
import pkg/codex/manifest
import pkg/codex/merkletree

import ../../../asynctest
import ../../helpers
import ../../helpers/mockdiscovery
import ../../examples

proc asBlock(m: Manifest): bt.Block =
  let mdata = m.encode().tryGet()
  bt.Block.new(data = mdata, codec = ManifestCodec).tryGet()

asyncchecksuite "Test Discovery Engine":
  let chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    blocks: seq[bt.Block]
    manifest: Manifest
    tree: CodexTree
    manifestBlock: bt.Block
    switch: Switch
    peerStore: PeerCtxStore
    blockDiscovery: MockDiscovery
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    (manifest, tree) = makeManifestAndTree(blocks).tryGet()
    manifestBlock = manifest.asBlock()
    blocks.add(manifestBlock)

    switch = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
    network = BlockExcNetwork.new(switch)
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    blockDiscovery = MockDiscovery.new()

  test "Should Query Wants":
    var
      localStore = CacheStore.new()
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis,
      )
      wants = blocks.mapIt(pendingBlocks.getWantHandle(it.cid))

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid
    ): Future[seq[SignedPeerRecord]] {.async, gcsafe.} =
      pendingBlocks.resolve(
        blocks.filterIt(it.cid == cid).mapIt(
          BlockDelivery(blk: it, address: it.address)
        )
      )

    await discoveryEngine.start()
    await allFuturesThrowing(allFinished(wants)).wait(1.seconds)
    await discoveryEngine.stop()

  test "Should queue discovery request":
    var
      localStore = CacheStore.new()
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis,
      )
      want = newFuture[void]()

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid
    ): Future[seq[SignedPeerRecord]] {.async, gcsafe.} =
      check cid == blocks[0].cid
      if not want.finished:
        want.complete()

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await want.wait(1.seconds)
    await discoveryEngine.stop()

  test "Should not request more than minPeersPerBlock":
    var
      localStore = CacheStore.new()
      minPeers = 2
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 5.minutes,
        minPeersPerBlock = minPeers,
      )
      want = newAsyncEvent()

    var pendingCids = newSeq[Cid]()
    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid
    ): Future[seq[SignedPeerRecord]] {.async, gcsafe.} =
      check cid in pendingCids
      pendingCids.keepItIf(it != cid)
      check peerStore.len < minPeers
      var peerCtx = BlockExcPeerCtx(id: PeerId.example)

      let address = BlockAddress(leaf: false, cid: cid)

      peerCtx.blocks[address] = Presence(address: address, price: 0.u256)
      peerStore.add(peerCtx)
      want.fire()

    await discoveryEngine.start()
    var idx = 0
    while peerStore.len < minPeers:
      let cid = blocks[idx].cid
      inc idx
      pendingCids.add(cid)
      discoveryEngine.queueFindBlocksReq(@[cid])
      await want.wait()
      want.clear()

    check peerStore.len == minPeers
    await discoveryEngine.stop()

  test "Should not request if there is already an inflight discovery request":
    var
      localStore = CacheStore.new()
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis,
        concurrentDiscReqs = 2,
      )
      reqs = newFuture[void]()
      count = 0

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid
    ): Future[seq[SignedPeerRecord]] {.gcsafe, async.} =
      check cid == blocks[0].cid
      if count > 0:
        check false
      count.inc

      await reqs # queue the request

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(200.millis)

    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(200.millis)

    reqs.complete()
    await discoveryEngine.stop()
