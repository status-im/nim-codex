import std/sequtils
import std/sugar
import std/tables

import pkg/chronos

import pkg/libp2p/errors

import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/manifest
import pkg/codex/merkletree
import pkg/codex/blocktype as bt

import ../../../asynctest
import ../../helpers
import ../../helpers/mockdiscovery
import ../../examples


asyncchecksuite "Block Advertising and Discovery":
  let chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    blocks: seq[bt.Block]
    manifest: Manifest
    tree: CodexTree
    manifestBlock: bt.Block
    switch: Switch
    peerStore: PeerCtxStore
    blockDiscovery: MockDiscovery
    discovery: DiscoveryEngine
    advertiser: Advertiser
    wallet: WalletRef
    network: BlockExcNetwork
    localStore: CacheStore
    engine: BlockExcEngine
    pendingBlocks: PendingBlocksManager

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    switch = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
    blockDiscovery = MockDiscovery.new()
    wallet = WalletRef.example
    network = BlockExcNetwork.new(switch)
    localStore = CacheStore.new(blocks.mapIt(it))
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    (manifest, tree) = makeManifestAndTree(blocks).tryGet()
    manifestBlock = bt.Block.new(
      manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    discovery = DiscoveryEngine.new(
      localStore,
      peerStore,
      network,
      blockDiscovery,
      pendingBlocks,
      minPeersPerBlock = 1)

    advertiser = Advertiser.new(
      localStore,
      blockDiscovery
    )

    engine = BlockExcEngine.new(
      localStore,
      wallet,
      network,
      discovery,
      advertiser,
      peerStore,
      pendingBlocks)

    switch.mount(network)

  test "Should discover want list":
    let
      pendingBlocks = blocks.mapIt(
        engine.pendingBlocks.getWantHandle(it.cid)
      )

    await engine.start()

    blockDiscovery.publishBlockProvideHandler =
      proc(d: MockDiscovery, cid: Cid): Future[void] {.async, gcsafe.} =
        return

    blockDiscovery.findBlockProvidersHandler =
      proc(d: MockDiscovery, cid: Cid): Future[seq[SignedPeerRecord]] {.async.} =
        await engine.resolveBlocks(blocks.filterIt(it.cid == cid))

    await allFuturesThrowing(
      allFinished(pendingBlocks))

    await engine.stop()

  test "Should advertise both manifests and trees":
    let
      cids = @[manifest.cid.tryGet, manifest.treeCid]
      advertised = initTable.collect:
        for cid in cids: {cid: newFuture[void]()}

    blockDiscovery
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid) {.async.} =
        if cid in advertised and not advertised[cid].finished():
          advertised[cid].complete()

    await engine.start()
    await allFuturesThrowing(
      allFinished(toSeq(advertised.values)))
    await engine.stop()

  test "Should not advertise local blocks":
    let
      blockCids = blocks.mapIt(it.cid)

    blockDiscovery
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid) {.async.} =
        check:
          cid notin blockCids

    await engine.start()
    await sleepAsync(3.seconds)
    await engine.stop()

  test "Should not launch discovery if remote peer has block":
    let
      pendingBlocks = blocks.mapIt(
        engine.pendingBlocks.getWantHandle(it.cid)
      )
      peerId = PeerId.example
      haves = collect(initTable()):
        for blk in blocks:
          { blk.address: Presence(address: blk.address, price: 0.u256) }

    engine.peers.add(
      BlockExcPeerCtx(
        id: peerId,
        blocks: haves
    ))

    blockDiscovery.findBlockProvidersHandler =
      proc(d: MockDiscovery, cid: Cid): Future[seq[SignedPeerRecord]] =
        check false

    await engine.start()
    engine.pendingBlocks.resolve(blocks.mapIt(BlockDelivery(blk: it, address: it.address)))

    await allFuturesThrowing(
      allFinished(pendingBlocks))

    await engine.stop()

proc asBlock(m: Manifest): bt.Block =
  let mdata = m.encode().tryGet()
  bt.Block.new(data = mdata, codec = ManifestCodec).tryGet()

asyncchecksuite "E2E - Multiple Nodes Discovery":
  var
    switch: seq[Switch]
    blockexc: seq[NetworkStore]
    manifests: seq[Manifest]
    mBlocks: seq[bt.Block]
    trees: seq[CodexTree]

  setup:
    for _ in 0..<4:
      let chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)
      var blocks = newSeq[bt.Block]()
      while true:
        let chunk = await chunker.getBytes()
        if chunk.len <= 0:
          break

        blocks.add(bt.Block.new(chunk).tryGet())
      let (manifest, tree) = makeManifestAndTree(blocks).tryGet()
      manifests.add(manifest)
      mBlocks.add(manifest.asBlock())
      trees.add(tree)

      let
        s = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
        blockDiscovery = MockDiscovery.new()
        wallet = WalletRef.example
        network = BlockExcNetwork.new(s)
        localStore = CacheStore.new()
        peerStore = PeerCtxStore.new()
        pendingBlocks = PendingBlocksManager.new()

        discovery = DiscoveryEngine.new(
          localStore,
          peerStore,
          network,
          blockDiscovery,
          pendingBlocks,
          minPeersPerBlock = 1)

        advertiser = Advertiser.new(
          localStore,
          blockDiscovery
        )

        engine = BlockExcEngine.new(
          localStore,
          wallet,
          network,
          discovery,
          advertiser,
          peerStore,
          pendingBlocks)
        networkStore = NetworkStore.new(engine, localStore)

      s.mount(network)
      switch.add(s)
      blockexc.add(networkStore)

  teardown:
    switch = @[]
    blockexc = @[]
    manifests = @[]
    mBlocks = @[]
    trees = @[]

  test "E2E - Should advertise and discover blocks":
    # Distribute the manifests and trees amongst 1..3
    # Ask 0 to download everything without connecting him beforehand

    var advertised: Table[Cid, SignedPeerRecord]

    MockDiscovery(blockexc[1].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[1].peerInfo.signedPeerRecord

    MockDiscovery(blockexc[2].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[2].peerInfo.signedPeerRecord

    MockDiscovery(blockexc[3].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[3].peerInfo.signedPeerRecord

    discard blockexc[1].engine.pendingBlocks.getWantHandle(mBlocks[0].cid)
    await blockexc[1].engine.blocksDeliveryHandler(switch[0].peerInfo.peerId, @[BlockDelivery(blk: mBlocks[0], address: BlockAddress(leaf: false, cid: mBlocks[0].cid))])

    discard blockexc[2].engine.pendingBlocks.getWantHandle(mBlocks[1].cid)
    await blockexc[2].engine.blocksDeliveryHandler(switch[0].peerInfo.peerId, @[BlockDelivery(blk: mBlocks[1], address: BlockAddress(leaf: false, cid: mBlocks[1].cid))])

    discard blockexc[3].engine.pendingBlocks.getWantHandle(mBlocks[2].cid)
    await blockexc[3].engine.blocksDeliveryHandler(switch[0].peerInfo.peerId, @[BlockDelivery(blk: mBlocks[2], address: BlockAddress(leaf: false, cid: mBlocks[2].cid))])

    MockDiscovery(blockexc[0].engine.discovery.discovery)
      .findBlockProvidersHandler = proc(d: MockDiscovery, cid: Cid):
        Future[seq[SignedPeerRecord]] {.async.} =
        if cid in advertised:
          result.add(advertised[cid])

    let futs = collect(newSeq):
      for m in mBlocks[0..2]:
        blockexc[0].engine.requestBlock(m.cid)

    await allFuturesThrowing(
      switch.mapIt(it.start()) &
      blockexc.mapIt(it.engine.start())).wait(10.seconds)

    await allFutures(futs).wait(10.seconds)

    await allFuturesThrowing(
      blockexc.mapIt(it.engine.stop()) &
      switch.mapIt(it.stop())).wait(10.seconds)

  test "E2E - Should advertise and discover blocks with peers already connected":
    # Distribute the blocks amongst 1..3
    # Ask 0 to download everything *WITH* connecting him beforehand

    var advertised: Table[Cid, SignedPeerRecord]

    MockDiscovery(blockexc[1].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[1].peerInfo.signedPeerRecord

    MockDiscovery(blockexc[2].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[2].peerInfo.signedPeerRecord

    MockDiscovery(blockexc[3].engine.discovery.discovery)
      .publishBlockProvideHandler = proc(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
        advertised[cid] = switch[3].peerInfo.signedPeerRecord

    discard blockexc[1].engine.pendingBlocks.getWantHandle(mBlocks[0].cid)
    await blockexc[1].engine.blocksDeliveryHandler(switch[0].peerInfo.peerId, @[BlockDelivery(blk: mBlocks[0], address: BlockAddress(leaf: false, cid: mBlocks[0].cid))])

    discard blockexc[2].engine.pendingBlocks.getWantHandle(mBlocks[1].cid)
    await blockexc[2].engine.blocksDeliveryHandler(switch[0].peerInfo.peerId, @[BlockDelivery(blk: mBlocks[1], address: BlockAddress(leaf: false, cid: mBlocks[1].cid))])

    discard blockexc[3].engine.pendingBlocks.getWantHandle(mBlocks[2].cid)
    await blockexc[3].engine.blocksDeliveryHandler(switch[0].peerInfo.peerId, @[BlockDelivery(blk: mBlocks[2], address: BlockAddress(leaf: false, cid: mBlocks[2].cid))])

    MockDiscovery(blockexc[0].engine.discovery.discovery)
      .findBlockProvidersHandler = proc(d: MockDiscovery, cid: Cid):
      Future[seq[SignedPeerRecord]] {.async.} =
        if cid in advertised:
          return @[advertised[cid]]

    let
      futs = mBlocks[0..2].mapIt(blockexc[0].engine.requestBlock(it.cid))

    await allFuturesThrowing(
      switch.mapIt(it.start()) &
      blockexc.mapIt(it.engine.start())).wait(10.seconds)

    await allFutures(futs).wait(10.seconds)

    await allFuturesThrowing(
      blockexc.mapIt(it.engine.stop()) &
      switch.mapIt(it.stop())).wait(10.seconds)
