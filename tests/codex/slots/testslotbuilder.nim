import std/sequtils
import std/math
import std/importutils
import std/sugar

import ../../asynctest

import pkg/chronos
import pkg/questionable/results
import pkg/codex/blocktype as bt
import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/chunker
import pkg/codex/merkletree
import pkg/codex/manifest {.all.}
import pkg/codex/utils
import pkg/codex/utils/digest
import pkg/codex/utils/poseidon2digest
import pkg/datastore
import pkg/poseidon2
import pkg/poseidon2/io
import pkg/constantine/math/io/io_fields

import ./helpers
import ../helpers
import ../examples
import ../merkletree/helpers

import pkg/codex/indexingstrategy {.all.}
import pkg/codex/slots {.all.}

privateAccess(Poseidon2Builder) # enable access to private fields
privateAccess(Manifest) # enable access to private fields

const
  Strategy = SteppedStrategy

suite "Slot builder":
  let
    blockSize = NBytes 1024
    cellSize = NBytes 64
    ecK = 3
    ecM = 2

    numSlots = ecK + ecM
    numDatasetBlocks = 8
    numTotalBlocks = calcEcBlocksCount(numDatasetBlocks, ecK, ecM)  # total number of blocks in the dataset after
                                                                    # EC (should will match number of slots)
    originalDatasetSize = numDatasetBlocks * blockSize.int
    totalDatasetSize    = numTotalBlocks * blockSize.int

    numSlotBlocks     = numTotalBlocks div numSlots
    numBlockCells     = (blockSize div cellSize).int                      # number of cells per block
    numSlotCells      = numSlotBlocks * numBlockCells                     # number of uncorrected slot cells
    pow2SlotCells     = nextPowerOfTwo(numSlotCells)                      # pow2 cells per slot
    numPadSlotBlocks  = (pow2SlotCells div numBlockCells) - numSlotBlocks # pow2 blocks per slot

    numSlotBlocksTotal  =                                                 # pad blocks per slot
      if numPadSlotBlocks > 0:
          numPadSlotBlocks + numSlotBlocks
        else:
          numSlotBlocks

    numBlocksTotal  = numSlotBlocksTotal * numSlots

    # empty digest
    emptyDigest = SpongeMerkle.digest(newSeq[byte](blockSize.int), cellSize.int)
    repoTmp = TempLevelDb.new()
    metaTmp = TempLevelDb.new()

  var
    datasetBlocks: seq[bt.Block]
    padBlocks: seq[bt.Block]
    localStore: BlockStore
    manifest: Manifest
    protectedManifest: Manifest
    builder: Poseidon2Builder
    chunker: Chunker

  setup:
    let
      repoDs = repoTmp.newDb()
      metaDs = metaTmp.newDb()

    localStore = RepoStore.new(repoDs, metaDs)
    chunker = RandomChunker.new(Rng.instance(), size = totalDatasetSize, chunkSize = blockSize)
    datasetBlocks = await chunker.createBlocks(localStore)

    (manifest, protectedManifest) =
        await createProtectedManifest(
          datasetBlocks,
          localStore,
          numDatasetBlocks,
          ecK, ecM,
          blockSize,
          originalDatasetSize,
          totalDatasetSize)

  teardown:
    await localStore.close()
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()

    # TODO: THIS IS A BUG IN asynctest, because it doesn't release the
    #       objects after the test is done, so we need to do it manually
    #
    # Need to reset all objects because otherwise they get
    # captured by the test runner closures, not good!
    reset(datasetBlocks)
    reset(localStore)
    reset(manifest)
    reset(protectedManifest)
    reset(builder)
    reset(chunker)

  test "Can only create builder with protected manifest":
    let
      unprotectedManifest = Manifest.new(
        treeCid = Cid.example,
        blockSize = blockSize.NBytes,
        datasetSize = originalDatasetSize.NBytes)

    check:
      Poseidon2Builder.new(localStore, unprotectedManifest, cellSize = cellSize)
        .error.msg == "Manifest is not protected."

  test "Number of blocks must be devisable by number of slots":
    let
      mismatchManifest = Manifest.new(
        manifest = Manifest.new(
          treeCid = Cid.example,
          blockSize = blockSize.NBytes,
          datasetSize = originalDatasetSize.NBytes),
        treeCid = Cid.example,
        datasetSize = totalDatasetSize.NBytes,
        ecK = ecK - 1,
        ecM = ecM,
        strategy = Strategy)

    check:
      Poseidon2Builder.new(localStore, mismatchManifest, cellSize = cellSize)
        .error.msg == "Number of blocks must be divisable by number of slots."

  test "Block size must be divisable by cell size":
    let
      mismatchManifest = Manifest.new(
        manifest = Manifest.new(
          treeCid = Cid.example,
          blockSize = (blockSize + 1).NBytes,
          datasetSize = (originalDatasetSize - 1).NBytes),
        treeCid = Cid.example,
        datasetSize = (totalDatasetSize - 1).NBytes,
        ecK = ecK,
        ecM = ecM,
        strategy = Strategy)

    check:
      Poseidon2Builder.new(localStore, mismatchManifest, cellSize = cellSize)
        .error.msg == "Block size must be divisable by cell size."

  test "Should build correct slot builder":
    builder = Poseidon2Builder.new(
      localStore,
      protectedManifest,
      cellSize = cellSize).tryGet()

    check:
      builder.cellSize == cellSize
      builder.numSlots == numSlots
      builder.numBlockCells == numBlockCells
      builder.numSlotBlocks == numSlotBlocksTotal
      builder.numSlotCells == pow2SlotCells
      builder.numBlocks == numBlocksTotal

  test "Should build slot hashes for all slots":
    let
      steppedStrategy = Strategy.init(
        0, numBlocksTotal - 1, numSlots)

      builder = Poseidon2Builder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

    for i in 0..<numSlots:
      let
        expectedHashes = collect(newSeq):
          for j, idx in steppedStrategy.getIndicies(i):
            if j > (protectedManifest.numSlotBlocks - 1):
              emptyDigest
            else:
              SpongeMerkle.digest(datasetBlocks[idx].data, cellSize.int)

        cellHashes = (await builder.getCellHashes(i)).tryGet()

      check:
        cellHashes.len == expectedHashes.len
        cellHashes == expectedHashes

  test "Should build slot trees for all slots":
    let
      steppedStrategy = Strategy.init(
        0, numBlocksTotal - 1, numSlots)

      builder = Poseidon2Builder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

    for i in 0..<numSlots:
      let
        expectedHashes = collect(newSeq):
          for j, idx in steppedStrategy.getIndicies(i):
            if j > (protectedManifest.numSlotBlocks - 1):
              emptyDigest
            else:
              SpongeMerkle.digest(datasetBlocks[idx].data, cellSize.int)

        expectedRoot = Merkle.digest(expectedHashes)
        slotTree = (await builder.buildSlotTree(i)).tryGet()

      check:
        slotTree.root().tryGet() == expectedRoot

  test "Should persist trees for all slots":
    let
      builder = Poseidon2Builder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

    for i in 0..<numSlots:
      let
        slotTree = (await builder.buildSlotTree(i)).tryGet()
        slotRoot = (await builder.buildSlot(i)).tryGet()
        slotCid = slotRoot.toSlotCid().tryGet()

      for cellIndex in 0..<numPadSlotBlocks:
        let
          (cellCid, proof) = (await localStore.getCidAndProof(slotCid, cellIndex)).tryGet()
          verifiableProof = proof.toVerifiableProof().tryGet()
          posProof = slotTree.getProof(cellIndex).tryGet()

        check:
          verifiableProof.path == posProof.path
          verifiableProof.index == posProof.index
          verifiableProof.nleaves == posProof.nleaves

  test "Should build correct verification root":
    let
      steppedStrategy = Strategy.init(0, numBlocksTotal - 1, numSlots)
      builder = Poseidon2Builder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

    (await builder.buildSlots()).tryGet
    let
      slotsHashes = collect(newSeq):
        for i in 0..<numSlots:
          let
            slotHashes = collect(newSeq):
              for j, idx in steppedStrategy.getIndicies(i):
                if j > (protectedManifest.numSlotBlocks - 1):
                  emptyDigest
                else:
                  SpongeMerkle.digest(datasetBlocks[idx].data, cellSize.int)

          Merkle.digest(slotHashes)

      expectedRoot = Merkle.digest(slotsHashes)
      rootHash = builder.buildVerifyTree(builder.slotRoots).tryGet().root.tryGet()

    check:
      expectedRoot == rootHash

  test "Should build correct verification root manifest":
    let
      steppedStrategy = Strategy.init(0, numBlocksTotal - 1, numSlots)
      builder = Poseidon2Builder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

      slotsHashes = collect(newSeq):
        for i in 0..<numSlots:
          let
            slotHashes = collect(newSeq):
              for j, idx in steppedStrategy.getIndicies(i):
                if j > (protectedManifest.numSlotBlocks - 1):
                  emptyDigest
                else:
                  SpongeMerkle.digest(datasetBlocks[idx].data, cellSize.int)

          Merkle.digest(slotHashes)

      expectedRoot = Merkle.digest(slotsHashes)
      manifest = (await builder.buildManifest()).tryGet()
      mhash = manifest.verifyRoot.mhash.tryGet()
      mhashBytes = mhash.digestBytes
      rootHash = Poseidon2Hash.fromBytes(mhashBytes.toArray32).get

    check:
      expectedRoot == rootHash

  test "Should not build from verifiable manifest with 0 slots":
    var
      builder = Poseidon2Builder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()
      verifyManifest = (await builder.buildManifest()).tryGet()

    verifyManifest.slotRoots = @[]
    check Poseidon2Builder.new(
        localStore,
        verifyManifest,
        cellSize = cellSize).isErr

  test "Should not build from verifiable manifest with incorrect number of slots":
    var
      builder = Poseidon2Builder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

      verifyManifest = (await builder.buildManifest()).tryGet()

    verifyManifest.slotRoots.del(
      verifyManifest.slotRoots.len - 1
    )

    check Poseidon2Builder.new(
        localStore,
        verifyManifest,
        cellSize = cellSize).isErr

  test "Should not build from verifiable manifest with invalid verify root":
    let
      builder = Poseidon2Builder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

    var
      verifyManifest = (await builder.buildManifest()).tryGet()

    rng.shuffle(
      Rng.instance,
      verifyManifest.verifyRoot.data.buffer)

    check Poseidon2Builder.new(
        localStore,
        verifyManifest,
        cellSize = cellSize).isErr

  test "Should build from verifiable manifest":
    let
      builder = Poseidon2Builder.new(
        localStore,
        protectedManifest,
        cellSize = cellSize).tryGet()

      verifyManifest = (await builder.buildManifest()).tryGet()

      verificationBuilder = Poseidon2Builder.new(
        localStore,
        verifyManifest,
        cellSize = cellSize).tryGet()

    check:
      builder.slotRoots == verificationBuilder.slotRoots
      builder.verifyRoot == verificationBuilder.verifyRoot
