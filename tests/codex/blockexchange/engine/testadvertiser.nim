import std/sequtils
import std/random

import pkg/chronos
import pkg/libp2p/routing_record
import pkg/codexdht/discv5/protocol as discv5

import pkg/codex/blockexchange
import pkg/codex/stores
import pkg/codex/chunker
import pkg/codex/discovery
import pkg/codex/blocktype as bt
import pkg/codex/manifest

import ../../../asynctest
import ../../helpers
import ../../helpers/mockdiscovery
import ../../examples

asyncchecksuite "Advertiser":
  var
    blockDiscovery: MockDiscovery
    localStore: BlockStore
    advertiser: Advertiser
  let
    manifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 123.NBytes,
      datasetSize = 234.NBytes)
    manifestBlk = Block.new(data = manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

  setup:
    blockDiscovery = MockDiscovery.new()
    localStore = CacheStore.new()

    advertiser = Advertiser.new(
      localStore,
      blockDiscovery
    )

    await advertiser.start()

  teardown:
    await advertiser.stop()

  test "blockStored should queue manifest Cid for advertising":
    (await localStore.putBlock(manifestBlk)).tryGet()

    check:
      manifestBlk.cid in advertiser.advertiseQueue

  test "blockStored should queue tree Cid for advertising":
    (await localStore.putBlock(manifestBlk)).tryGet()

    check:
      manifest.treeCid in advertiser.advertiseQueue

  test "blockStored should not queue non-manifest non-tree CIDs for discovery":
    let blk = bt.Block.example
      
    (await localStore.putBlock(blk)).tryGet()

    check:
      blk.cid notin advertiser.advertiseQueue

  test "Should not queue if there is already an inflight advertise request":
    var
      reqs = newFuture[void]()
      manifestCount = 0
      treeCount = 0

    blockDiscovery.publishBlockProvideHandler =
      proc(d: MockDiscovery, cid: Cid) {.async, gcsafe.} =
        if cid == manifestBlk.cid:
          inc manifestCount
        if cid == manifest.treeCid:
          inc treeCount

        await reqs # queue the request

    (await localStore.putBlock(manifestBlk)).tryGet()
    (await localStore.putBlock(manifestBlk)).tryGet()

    reqs.complete()
    check eventually manifestCount == 1
    check eventually treeCount == 1

  test "Should advertise existing manifests and their trees":
    let
      newStore = CacheStore.new([manifestBlk])

    await advertiser.stop()
    advertiser = Advertiser.new(
      newStore,
      blockDiscovery
    )
    await advertiser.start()

    check eventually manifestBlk.cid in advertiser.advertiseQueue
    check eventually manifest.treeCid in advertiser.advertiseQueue

  test "Stop should clear onBlockStored callback":
    await advertiser.stop()

    check:
      localStore.onBlockStored.isNone()
