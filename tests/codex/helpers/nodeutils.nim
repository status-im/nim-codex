import std/sequtils

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors

import pkg/codex/discovery
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/blockexchange

import ../examples

type
  NodesComponents* = tuple[
    switch: Switch,
    blockDiscovery: Discovery,
    wallet: WalletRef,
    network: BlockExcNetwork,
    localStore: BlockStore,
    peerStore: PeerCtxStore,
    pendingBlocks: PendingBlocksManager,
    discovery: DiscoveryEngine,
    engine: BlockExcEngine,
    networkStore: NetworkStore]

proc generateNodes*(
    num: Natural,
    blocks: openArray[bt.Block] = []
): seq[NodesComponents] =
  for i in 0..<num:
    let
      switch = newStandardSwitch(transportFlags = {ServerFlags.ReuseAddr})
      discovery = Discovery.new(
        switch.peerInfo.privateKey,
        announceAddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/0")
          .expect("Should return multiaddress")])
      wallet = WalletRef.example
      network = BlockExcNetwork.new(switch)
      localStore = CacheStore.new(blocks.mapIt( it ))
      peerStore = PeerCtxStore.new()
      pendingBlocks = PendingBlocksManager.new()
      advertiser = Advertiser.new(localStore, discovery)
      blockDiscovery = DiscoveryEngine.new(localStore, peerStore, network, discovery, pendingBlocks)
      engine = BlockExcEngine.new(localStore, wallet, network, blockDiscovery, advertiser, peerStore, pendingBlocks)
      networkStore = NetworkStore.new(engine, localStore)

    switch.mount(network)
    result.add((
      switch,
      discovery,
      wallet,
      network,
      localStore,
      peerStore,
      pendingBlocks,
      blockDiscovery,
      engine,
      networkStore))

proc connectNodes*(nodes: seq[Switch]) {.async.} =
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        await dialer.connect(node.peerInfo.peerId, node.peerInfo.addrs)

proc connectNodes*(nodes: seq[NodesComponents]) {.async.} =
  await connectNodes(nodes.mapIt( it.switch ))
