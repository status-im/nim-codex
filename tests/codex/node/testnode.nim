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

import pkg/codex/node {.all.}

import ../../asynctest
import ../examples
import ../helpers
import ../helpers/mockmarket
import ../helpers/mockclock

import ./helpers

privateAccess(CodexNodeRef) # enable access to private fields

asyncchecksuite "Test Node - Basic":
  setupAndTearDown()

  setup:
    await node.start()

  test "Fetch Manifest":
    let
      manifest = await storeDataGetManifest(localStore, chunker)

      manifestBlock = bt.Block.new(
        manifest.encode().tryGet(),
        codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    let
      fetched = (await node.fetchManifest(manifestBlock.cid)).tryGet()

    check:
      fetched == manifest

  test "Should not lookup non-existing blocks twice":
    # https://github.com/codex-storage/nim-codex/issues/699
    let
      cstore = CountingStore.new(engine, localStore)
      node = CodexNodeRef.new(switch, cstore, engine, blockDiscovery)
      missingCid = Cid.init(
        "zDvZRwzmCvtiyubW9AecnxgLnXK8GrBvpQJBDzToxmzDN6Nrc2CZ").get()

    engine.blockFetchTimeout = timer.milliseconds(100)

    discard await node.retrieve(missingCid, local = false)

    let lookupCount = cstore.lookups.getOrDefault(missingCid)
    check lookupCount == 1

  test "Block Batching":
    let manifest = await storeDataGetManifest(localStore, chunker)

    for batchSize in 1..12:
      (await node.fetchBatched(
        manifest,
        batchSize = batchSize,
        proc(blocks: seq[bt.Block]): Future[?!void] {.gcsafe, async.} =
          check blocks.len > 0 and blocks.len <= batchSize
          return success()
      )).tryGet()

  test "Store and retrieve Data Stream":
    let
      stream = BufferStream.new()
      storeFut = node.store(stream)
      oddChunkSize = math.trunc(DefaultBlockSize.float / 3.14).NBytes  # Let's check that node.store can correctly rechunk these odd chunks
      oddChunker = FileChunker.new(file = file, chunkSize = oddChunkSize, pad = false)  # TODO: doesn't work with pad=tue

    var
      original: seq[byte]

    try:
      while (
        let chunk = await oddChunker.getBytes();
        chunk.len > 0):
        original &= chunk
        await stream.pushData(chunk)
    finally:
      await stream.pushEof()
      await stream.close()

    let
      manifestCid = (await storeFut).tryGet()
      manifestBlock = (await localStore.getBlock(manifestCid)).tryGet()
      localManifest = Manifest.decode(manifestBlock).tryGet()
      data = await (await node.retrieve(manifestCid)).drain()

    check:
      data.len == localManifest.datasetSize.int
      data.len == original.len
      sha256.digest(data) == sha256.digest(original)

  test "Retrieve One Block":
    let
      testString = "Block 1"
      blk = bt.Block.new(testString.toBytes).tryGet()

    (await localStore.putBlock(blk)).tryGet()
    let stream = (await node.retrieve(blk.cid)).tryGet()
    defer: await stream.close()

    var data = newSeq[byte](testString.len)
    await stream.readExactly(addr data[0], data.len)
    check string.fromBytes(data) == testString

  test "Setup purchase request":
    let
      erasure = Erasure.new(store, taskpool)
      manifest = await storeDataGetManifest(localStore, chunker)
      manifestBlock = bt.Block.new(
        manifest.encode().tryGet(),
        codec = ManifestCodec).tryGet()
      protected = (await erasure.encode(manifest, 3, 2)).tryGet()
      builder = Poseidon2Builder.new(localStore, protected).tryGet()
      verifiable = (await builder.buildManifest()).tryGet()
      verifiableBlock = bt.Block.new(
        verifiable.encode().tryGet(),
        codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    let
      request = (await node.setupRequest(
        cid = manifestBlock.cid,
        nodes = 5,
        tolerance = 2,
        duration = 100.u256,
        reward = 2.u256,
        proofProbability = 3.u256,
        expiry = 200.u256,
        collateral = 200.u256)).tryGet

    check:
      (await verifiableBlock.cid in localStore) == true
      request.content.cid == $verifiableBlock.cid
      request.content.merkleRoot == builder.verifyRoot.get.toBytes
