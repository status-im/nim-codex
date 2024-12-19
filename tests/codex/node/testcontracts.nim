import std/os
import std/options
import std/math
import std/times
import std/sequtils
import std/importutils
import std/cpuinfo

import pkg/chronos
import pkg/stew/byteutils
import pkg/datastore
import pkg/datastore/typedds
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/poseidon2
import pkg/poseidon2/io
import pkg/taskpools

import pkg/nitro
import pkg/codexdht/discv5/protocol as discv5

import pkg/codex/logutils
import pkg/codex/stores
import pkg/codex/clock
import pkg/codex/contracts
import pkg/codex/systemclock
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/slots
import pkg/codex/manifest
import pkg/codex/discovery
import pkg/codex/erasure
import pkg/codex/merkletree
import pkg/codex/blocktype as bt
import pkg/codex/stores/repostore/coders
import pkg/codex/utils/asynciter
import pkg/codex/indexingstrategy

import pkg/codex/node {.all.}

import ../../asynctest
import ../../examples
import ../helpers
import ../helpers/mockmarket
import ../helpers/mockclock

import ./helpers

privateAccess(CodexNodeRef) # enable access to private fields

asyncchecksuite "Test Node - Host contracts":
  setupAndTearDown()

  var
    sales: Sales
    purchasing: Purchasing
    manifest: Manifest
    manifestCidStr: string
    manifestCid: Cid
    market: MockMarket
    builder: Poseidon2Builder
    verifiable: Manifest
    verifiableBlock: bt.Block
    protected: Manifest

  setup:
    # Setup Host Contracts and dependencies
    market = MockMarket.new()
    sales = Sales.new(market, clock, localStore)

    node.contracts = (
      none ClientInteractions,
      some HostInteractions.new(clock, sales),
      none ValidatorInteractions)

    await node.start()

    # Populate manifest in local store
    manifest = await storeDataGetManifest(localStore, chunker)
    let
      manifestBlock = bt.Block.new(
        manifest.encode().tryGet(),
        codec = ManifestCodec).tryGet()
      erasure = Erasure.new(store, taskpool)

    manifestCid = manifestBlock.cid
    manifestCidStr = $(manifestCid)

    (await localStore.putBlock(manifestBlock)).tryGet()

    protected = (await erasure.encode(manifest, 3, 2)).tryGet()
    builder = Poseidon2Builder.new(localStore, protected).tryGet()
    verifiable = (await builder.buildManifest()).tryGet()
    verifiableBlock = bt.Block.new(
      verifiable.encode().tryGet(),
      codec = ManifestCodec).tryGet()

    (await localStore.putBlock(verifiableBlock)).tryGet()

  test "onExpiryUpdate callback is set":
    check sales.onExpiryUpdate.isSome

  test "onExpiryUpdate callback":
    let
      # The blocks have set default TTL, so in order to update it we have to have larger TTL
      expectedExpiry: SecondsSince1970 = clock.now + DefaultBlockTtl.seconds + 11123
      expiryUpdateCallback = !sales.onExpiryUpdate

    (await expiryUpdateCallback(manifestCidStr, expectedExpiry)).tryGet()

    for index in 0..<manifest.blocksCount:
      let
        blk = (await localStore.getBlock(manifest.treeCid, index)).tryGet
        key = (createBlockExpirationMetadataKey(blk.cid)).tryGet
        bytes = (await localStoreMetaDs.get(key)).tryGet
        blkMd = BlockMetadata.decode(bytes).tryGet

      check blkMd.expiry == expectedExpiry

  test "onStore callback is set":
    check sales.onStore.isSome

  test "onStore callback":
    let onStore = !sales.onStore
    var request = StorageRequest.example
    request.content.cid = $verifiableBlock.cid
    request.expiry = (getTime() + DefaultBlockTtl.toTimesDuration + 1.hours).toUnix.u256
    var fetchedBytes: uint = 0

    let onBlocks = proc(blocks: seq[bt.Block]): Future[?!void] {.async.} =
      for blk in blocks:
        fetchedBytes += blk.data.len.uint
      return success()

    (await onStore(request, 1.u256, onBlocks)).tryGet()
    check fetchedBytes == 12 * DefaultBlockSize.uint

    let indexer = verifiable.protectedStrategy.init(
      0, verifiable.numSlotBlocks() - 1, verifiable.numSlots)

    for index in indexer.getIndicies(1):
      let
        blk = (await localStore.getBlock(verifiable.treeCid, index)).tryGet
        key = (createBlockExpirationMetadataKey(blk.cid)).tryGet
        bytes = (await localStoreMetaDs.get(key)).tryGet
        blkMd = BlockMetadata.decode(bytes).tryGet

      check blkMd.expiry == request.expiry.toSecondsSince1970
