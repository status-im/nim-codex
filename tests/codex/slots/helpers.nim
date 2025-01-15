import std/sugar

import pkg/chronos
import pkg/libp2p/cid

import pkg/codex/codextypes
import pkg/codex/stores
import pkg/codex/merkletree
import pkg/codex/manifest
import pkg/codex/blocktype as bt
import pkg/codex/chunker
import pkg/codex/indexingstrategy
import pkg/codex/slots
import pkg/codex/rng

import ../helpers

proc storeManifest*(
    store: BlockStore, manifest: Manifest
): Future[?!bt.Block] {.async.} =
  without encodedVerifiable =? manifest.encode(), err:
    trace "Unable to encode manifest"
    return failure(err)

  without blk =? bt.Block.new(data = encodedVerifiable, codec = ManifestCodec), error:
    trace "Unable to create block from manifest"
    return failure(error)

  if err =? (await store.putBlock(blk)).errorOption:
    trace "Unable to store manifest block", cid = blk.cid, err = err.msg
    return failure(err)

  success blk

proc makeManifest*(
    cids: seq[Cid],
    datasetSize: NBytes,
    blockSize: NBytes,
    store: BlockStore,
    hcodec = Sha256HashCodec,
    dataCodec = BlockCodec,
): Future[?!Manifest] {.async.} =
  without tree =? CodexTree.init(cids), err:
    return failure(err)

  without treeCid =? tree.rootCid(CIDv1, dataCodec), err:
    return failure(err)

  for index, cid in cids:
    without proof =? tree.getProof(index), err:
      return failure(err)

    if err =? (await store.putCidAndProof(treeCid, index, cid, proof)).errorOption:
      # TODO add log here
      return failure(err)

  let manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = blockSize,
    datasetSize = datasetSize,
    version = CIDv1,
    hcodec = hcodec,
    codec = dataCodec,
  )

  without manifestBlk =? await store.storeManifest(manifest), err:
    trace "Unable to store manifest"
    return failure(err)

  success manifest

proc createBlocks*(
    chunker: Chunker, store: BlockStore
): Future[seq[bt.Block]] {.async.} =
  collect(newSeq):
    while (let chunk = await chunker.getBytes(); chunk.len > 0):
      let blk = bt.Block.new(chunk).tryGet()
      discard await store.putBlock(blk)
      blk

proc createProtectedManifest*(
    datasetBlocks: seq[bt.Block],
    store: BlockStore,
    numDatasetBlocks: int,
    ecK: int,
    ecM: int,
    blockSize: NBytes,
    originalDatasetSize: int,
    totalDatasetSize: int,
): Future[tuple[manifest: Manifest, protected: Manifest]] {.async.} =
  let
    cids = datasetBlocks.mapIt(it.cid)
    datasetTree = CodexTree.init(cids[0 ..< numDatasetBlocks]).tryGet()
    datasetTreeCid = datasetTree.rootCid().tryGet()

    protectedTree = CodexTree.init(cids).tryGet()
    protectedTreeCid = protectedTree.rootCid().tryGet()

  for index, cid in cids[0 ..< numDatasetBlocks]:
    let proof = datasetTree.getProof(index).tryGet()
    (await store.putCidAndProof(datasetTreeCid, index, cid, proof)).tryGet

  for index, cid in cids:
    let proof = protectedTree.getProof(index).tryGet()
    (await store.putCidAndProof(protectedTreeCid, index, cid, proof)).tryGet

  let
    manifest = Manifest.new(
      treeCid = datasetTreeCid,
      blockSize = blockSize,
      datasetSize = originalDatasetSize.NBytes,
    )

    protectedManifest = Manifest.new(
      manifest = manifest,
      treeCid = protectedTreeCid,
      datasetSize = totalDatasetSize.NBytes,
      ecK = ecK,
      ecM = ecM,
      strategy = SteppedStrategy,
    )

    manifestBlock =
      bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

    protectedManifestBlock =
      bt.Block.new(protectedManifest.encode().tryGet(), codec = ManifestCodec).tryGet()

  (await store.putBlock(manifestBlock)).tryGet()
  (await store.putBlock(protectedManifestBlock)).tryGet()

  (manifest, protectedManifest)

proc createVerifiableManifest*(
    store: BlockStore,
    numDatasetBlocks: int,
    ecK: int,
    ecM: int,
    blockSize: NBytes,
    cellSize: NBytes,
): Future[tuple[manifest: Manifest, protected: Manifest, verifiable: Manifest]] {.
    async
.} =
  let
    numSlots = ecK + ecM
    numTotalBlocks = calcEcBlocksCount(numDatasetBlocks, ecK, ecM)
      # total number of blocks in the dataset after
      # EC (should will match number of slots)
    originalDatasetSize = numDatasetBlocks * blockSize.int
    totalDatasetSize = numTotalBlocks * blockSize.int

    chunker =
      RandomChunker.new(Rng.instance(), size = totalDatasetSize, chunkSize = blockSize)
    datasetBlocks = await chunker.createBlocks(store)

    (manifest, protectedManifest) = await createProtectedManifest(
      datasetBlocks, store, numDatasetBlocks, ecK, ecM, blockSize, originalDatasetSize,
      totalDatasetSize,
    )

    builder = Poseidon2Builder.new(store, protectedManifest, cellSize = cellSize).tryGet
    verifiableManifest = (await builder.buildManifest()).tryGet

  # build the slots and manifest
  (manifest, protectedManifest, verifiableManifest)
