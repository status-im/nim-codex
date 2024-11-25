## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/options
import std/sequtils
import std/strformat
import std/sugar
import std/cpuinfo
import times

import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/poseidon2

import pkg/libp2p/[switch, multicodec, multihash]
import pkg/libp2p/stream/bufferstream

# TODO: remove once exported by libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/signed_envelope
import pkg/taskpools

import ./chunker
import ./slots
import ./clock
import ./blocktype as bt
import ./manifest
import ./merkletree
import ./stores
import ./blockexchange
import ./streams
import ./erasure
import ./discovery
import ./contracts
import ./indexingstrategy
import ./utils
import ./errors
import ./logutils
import ./utils/poseidon2digest
import ./utils/asynciter

export logutils

logScope:
  topics = "codex node"

const
  FetchBatch = 200

type
  Contracts* = tuple
    client: ?ClientInteractions
    host: ?HostInteractions
    validator: ?ValidatorInteractions

  CodexNode* = object
    switch: Switch
    networkId: PeerId
    networkStore: NetworkStore
    engine: BlockExcEngine
    prover: ?Prover
    discovery: Discovery
    contracts*: Contracts
    clock*: Clock
    storage*: Contracts
    taskpool*: Taskpool

  CodexNodeRef* = ref CodexNode

  OnManifest* = proc(cid: Cid, manifest: Manifest): void {.gcsafe, raises: [].}
  BatchProc* = proc(blocks: seq[bt.Block]): Future[?!void] {.gcsafe, raises: [].}

func switch*(self: CodexNodeRef): Switch =
  return self.switch

func blockStore*(self: CodexNodeRef): BlockStore =
  return self.networkStore

func engine*(self: CodexNodeRef): BlockExcEngine =
  return self.engine

func discovery*(self: CodexNodeRef): Discovery =
  return self.discovery

proc storeManifest*(
  self: CodexNodeRef,
  manifest: Manifest): Future[?!bt.Block] {.async.} =
  without encodedVerifiable =? manifest.encode(), err:
    trace "Unable to encode manifest"
    return failure(err)

  without blk =? bt.Block.new(data = encodedVerifiable, codec = ManifestCodec), error:
    trace "Unable to create block from manifest"
    return failure(error)

  if err =? (await self.networkStore.putBlock(blk)).errorOption:
    trace "Unable to store manifest block", cid = blk.cid, err = err.msg
    return failure(err)

  success blk

proc fetchManifest*(
  self: CodexNodeRef,
  cid: Cid): Future[?!Manifest] {.async.} =
  ## Fetch and decode a manifest block
  ##

  if err =? cid.isManifest.errorOption:
    return failure "CID has invalid content type for manifest {$cid}"

  trace "Retrieving manifest for cid", cid

  without blk =? await self.networkStore.getBlock(BlockAddress.init(cid)), err:
    trace "Error retrieve manifest block", cid, err = err.msg
    return failure err

  trace "Decoding manifest for cid", cid

  without manifest =? Manifest.decode(blk), err:
    trace "Unable to decode as manifest", err = err.msg
    return failure("Unable to decode as manifest")

  trace "Decoded manifest", cid

  return manifest.success

proc findPeer*(
  self: CodexNodeRef,
  peerId: PeerId): Future[?PeerRecord] {.async.} =
  ## Find peer using the discovery service from the given CodexNode
  ##
  return await self.discovery.findPeer(peerId)

proc connect*(
  self: CodexNodeRef,
  peerId: PeerId,
  addrs: seq[MultiAddress]
): Future[void] =
  self.switch.connect(peerId, addrs)

proc updateExpiry*(
  self: CodexNodeRef,
  manifestCid: Cid,
  expiry: SecondsSince1970): Future[?!void] {.async.} =

  without manifest =? await self.fetchManifest(manifestCid), error:
    trace "Unable to fetch manifest for cid", manifestCid
    return failure(error)

  try:
    let
      ensuringFutures = Iter[int].new(0..<manifest.blocksCount)
        .mapIt(self.networkStore.localStore.ensureExpiry( manifest.treeCid, it, expiry ))
    await allFuturesThrowing(ensuringFutures)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)

  return success()

proc fetchBatched*(
  self: CodexNodeRef,
  cid: Cid,
  iter: Iter[int],
  batchSize = FetchBatch,
  onBatch: BatchProc = nil): Future[?!void] {.async, gcsafe.} =
  ## Fetch blocks in batches of `batchSize`
  ##

  # TODO: doesn't work if callee is annotated with async
  # let
  #   iter = iter.map(
  #     (i: int) => self.networkStore.getBlock(BlockAddress.init(cid, i))
  #   )

  while not iter.finished:
    let blocks = collect:
      for i in 0..<batchSize:
        if not iter.finished:
          self.networkStore.getBlock(BlockAddress.init(cid, iter.next()))

    if blocksErr =? (await allFutureResult(blocks)).errorOption:
      return failure(blocksErr)

    if not onBatch.isNil and
      batchErr =? (await onBatch(blocks.mapIt( it.read.get ))).errorOption:
      return failure(batchErr)

  success()

proc fetchBatched*(
  self: CodexNodeRef,
  manifest: Manifest,
  batchSize = FetchBatch,
  onBatch: BatchProc = nil): Future[?!void] =
  ## Fetch manifest in batches of `batchSize`
  ##

  trace "Fetching blocks in batches of", size = batchSize

  let iter = Iter[int].new(0..<manifest.blocksCount)
  self.fetchBatched(manifest.treeCid, iter, batchSize, onBatch)

proc streamSingleBlock(
  self: CodexNodeRef,
  cid: Cid
): Future[?!LPstream] {.async.} =
  ## Streams the contents of a single block.
  ##
  trace "Streaming single block", cid = cid

  let
    stream = BufferStream.new()

  without blk =? (await self.networkStore.getBlock(BlockAddress.init(cid))), err:
    return failure(err)

  proc streamOneBlock(): Future[void] {.async.} =
    try:
      await stream.pushData(blk.data)
    except CatchableError as exc:
      trace "Unable to send block", cid, exc = exc.msg
      discard
    finally:
      await stream.pushEof()

  asyncSpawn streamOneBlock()
  LPStream(stream).success

proc streamEntireDataset(
  self: CodexNodeRef,
  manifest: Manifest,
  manifestCid: Cid,
): Future[?!LPStream] {.async.} =
  ## Streams the contents of the entire dataset described by the manifest.
  ##
  trace "Retrieving blocks from manifest", manifestCid

  if manifest.protected:
    # Retrieve, decode and save to the local store all EС groups
    proc erasureJob(): Future[?!void] {.async.} =
      try:
        # Spawn an erasure decoding job
        let
          erasure = Erasure.new(
            self.networkStore,
            leoEncoderProvider,
            leoDecoderProvider,
            self.taskpool)
        without _ =? (await erasure.decode(manifest)), error:
          error "Unable to erasure decode manifest", manifestCid, exc = error.msg
          return failure(error)

        return success()
      # --------------------------------------------------------------------------
      # FIXME this is a HACK so that the node does not crash during the workshop.
      #   We should NOT catch Defect.
      except Exception as exc:
        trace "Exception decoding manifest", manifestCid, exc = exc.msg
        return failure(exc.msg)
      # --------------------------------------------------------------------------

    if err =? (await erasureJob()).errorOption:
      return failure(err)

  # Retrieve all blocks of the dataset sequentially from the local store or network
  trace "Creating store stream for manifest", manifestCid
  LPStream(StoreStream.new(self.networkStore, manifest, pad = false)).success

proc retrieve*(
  self: CodexNodeRef,
  cid: Cid,
  local: bool = true): Future[?!LPStream] {.async.} =
  ## Retrieve by Cid a single block or an entire dataset described by manifest
  ##

  if local and not await (cid in self.networkStore):
    return failure((ref BlockNotFoundError)(msg: "Block not found in local store"))

  without manifest =? (await self.fetchManifest(cid)), err:
    if err of AsyncTimeoutError:
      return failure(err)

    return await self.streamSingleBlock(cid)

  await self.streamEntireDataset(manifest, cid)

proc store*(
  self: CodexNodeRef,
  stream: LPStream,
  filename: ?string = string.none,
  mimetype: ?string = string.none,
  blockSize = DefaultBlockSize): Future[?!Cid] {.async.} =
  ## Save stream contents as dataset with given blockSize
  ## to nodes's BlockStore, and return Cid of its manifest
  ##
  info "Storing data"

  let
    hcodec = Sha256HashCodec
    dataCodec = BlockCodec
    chunker = LPStreamChunker.new(stream, chunkSize = blockSize)

  var cids: seq[Cid]

  try:
    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      without mhash =? MultiHash.digest($hcodec, chunk).mapFailure, err:
        return failure(err)

      without cid =? Cid.init(CIDv1, dataCodec, mhash).mapFailure, err:
        return failure(err)

      without blk =? bt.Block.new(cid, chunk, verify = false):
        return failure("Unable to init block from chunk!")

      cids.add(cid)

      if err =? (await self.networkStore.putBlock(blk)).errorOption:
        error "Unable to store block", cid = blk.cid, err = err.msg
        return failure(&"Unable to store block {blk.cid}")
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)
  finally:
    await stream.close()

  without tree =? CodexTree.init(cids), err:
    return failure(err)

  without treeCid =? tree.rootCid(CIDv1, dataCodec), err:
    return failure(err)

  for index, cid in cids:
    without proof =? tree.getProof(index), err:
      return failure(err)
    if err =? (await self.networkStore.putCidAndProof(treeCid, index, cid, proof)).errorOption:
      # TODO add log here
      return failure(err)

  let manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = blockSize,
    datasetSize = NBytes(chunker.offset),
    version = CIDv1,
    hcodec = hcodec,
    codec = dataCodec,
    filename = filename,
    mimetype = mimetype,
    uploadedAt = now().utc.toTime.toUnix.some)

  without manifestBlk =? await self.storeManifest(manifest), err:
    error "Unable to store manifest"
    return failure(err)

  info "Stored data", manifestCid = manifestBlk.cid,
                      treeCid = treeCid,
                      blocks = manifest.blocksCount,
                      datasetSize = manifest.datasetSize,
                      filename = manifest.filename,
                      mimetype = manifest.mimetype

  return manifestBlk.cid.success

proc iterateManifests*(self: CodexNodeRef, onManifest: OnManifest) {.async.} =
  without cids =? await self.networkStore.listBlocks(BlockType.Manifest):
    warn "Failed to listBlocks"
    return

  for c in cids:
    if cid =? await c:
      without blk =? await self.networkStore.getBlock(cid):
        warn "Failed to get manifest block by cid", cid
        return

      without manifest =? Manifest.decode(blk):
        warn "Failed to decode manifest", cid
        return

      onManifest(cid, manifest)

proc setupRequest(
  self: CodexNodeRef,
  cid: Cid,
  duration: UInt256,
  proofProbability: UInt256,
  nodes: uint,
  tolerance: uint,
  reward: UInt256,
  collateral: UInt256,
  expiry:  UInt256): Future[?!StorageRequest] {.async.} =
  ## Setup slots for a given dataset
  ##

  let
    ecK = nodes - tolerance
    ecM = tolerance

  logScope:
    cid               = cid
    duration          = duration
    nodes             = nodes
    tolerance         = tolerance
    reward            = reward
    proofProbability  = proofProbability
    collateral        = collateral
    expiry            = expiry
    ecK               = ecK
    ecM               = ecM

  trace "Setting up slots"

  without manifest =? await self.fetchManifest(cid), error:
    trace "Unable to fetch manifest for cid"
    return failure error

  # ----------------------------------------------------------------------------
  # FIXME this is a BAND-AID to address
  #   https://github.com/codex-storage/nim-codex/issues/852 temporarily for the
  #   workshop. Remove this once we get that fixed.
  if manifest.blocksCount.uint == ecK:
    return failure("Cannot setup slots for a dataset with ecK == numBlocks. Please use a larger file or a different combination of `nodes` and `tolerance`.")
  # ----------------------------------------------------------------------------


  # Erasure code the dataset according to provided parameters
  let
    erasure = Erasure.new(
      self.networkStore.localStore,
      leoEncoderProvider,
      leoDecoderProvider,
      self.taskpool)

  without encoded =? (await erasure.encode(manifest, ecK, ecM)), error:
    trace "Unable to erasure code dataset"
    return failure(error)

  without builder =? Poseidon2Builder.new(self.networkStore.localStore, encoded), err:
    trace "Unable to create slot builder"
    return failure(err)

  without verifiable =? (await builder.buildManifest()), err:
    trace "Unable to build verifiable manifest"
    return failure(err)

  without manifestBlk =? await self.storeManifest(verifiable), err:
    trace "Unable to store verifiable manifest"
    return failure(err)

  let
    verifyRoot =
      if builder.verifyRoot.isNone:
          return failure("No slots root")
        else:
          builder.verifyRoot.get.toBytes

    request = StorageRequest(
      ask: StorageAsk(
        slots: verifiable.numSlots.uint64,
        slotSize: builder.slotBytes.uint.u256,
        duration: duration,
        proofProbability: proofProbability,
        reward: reward,
        collateral: collateral,
        maxSlotLoss: tolerance
      ),
      content: StorageContent(
        cid: $manifestBlk.cid, # TODO: why string?
        merkleRoot: verifyRoot
      ),
      expiry: expiry
    )

  trace "Request created", request = $request
  success request

proc requestStorage*(
  self: CodexNodeRef,
  cid: Cid,
  duration: UInt256,
  proofProbability: UInt256,
  nodes: uint,
  tolerance: uint,
  reward: UInt256,
  collateral: UInt256,
  expiry:  UInt256): Future[?!PurchaseId] {.async.} =
  ## Initiate a request for storage sequence, this might
  ## be a multistep procedure.
  ##

  logScope:
    cid               = cid
    duration          = duration
    nodes             = nodes
    tolerance         = tolerance
    reward            = reward
    proofProbability  = proofProbability
    collateral        = collateral
    expiry            = expiry.truncate(int64)
    now               = self.clock.now

  trace "Received a request for storage!"

  without contracts =? self.contracts.client:
    trace "Purchasing not available"
    return failure "Purchasing not available"

  without request =?
    (await self.setupRequest(
      cid,
      duration,
      proofProbability,
      nodes,
      tolerance,
      reward,
      collateral,
      expiry)), err:
    trace "Unable to setup request"
    return failure err

  let purchase = await contracts.purchasing.purchase(request)
  success purchase.id

proc onStore(
  self: CodexNodeRef,
  request: StorageRequest,
  slotIdx: UInt256,
  blocksCb: BlocksCb): Future[?!void] {.async.} =
  ## store data in local storage
  ##

  logScope:
    cid = request.content.cid
    slotIdx = slotIdx

  trace "Received a request to store a slot"

  without cid =? Cid.init(request.content.cid).mapFailure, err:
    trace "Unable to parse Cid", cid
    return failure(err)

  without manifest =? (await self.fetchManifest(cid)), err:
    trace "Unable to fetch manifest for cid", cid, err = err.msg
    return failure(err)

  without builder =? Poseidon2Builder.new(
    self.networkStore, manifest, manifest.verifiableStrategy
  ), err:
    trace "Unable to create slots builder", err = err.msg
    return failure(err)

  let
    slotIdx = slotIdx.truncate(int)
    expiry = request.expiry.toSecondsSince1970

  if slotIdx > manifest.slotRoots.high:
    trace "Slot index not in manifest", slotIdx
    return failure(newException(CodexError, "Slot index not in manifest"))

  proc updateExpiry(blocks: seq[bt.Block]): Future[?!void] {.async.} =
    trace "Updating expiry for blocks", blocks = blocks.len

    let ensureExpiryFutures = blocks.mapIt(self.networkStore.ensureExpiry(it.cid, expiry))
    if updateExpiryErr =? (await allFutureResult(ensureExpiryFutures)).errorOption:
      return failure(updateExpiryErr)

    if not blocksCb.isNil and err =? (await blocksCb(blocks)).errorOption:
      trace "Unable to process blocks", err = err.msg
      return failure(err)

    return success()

  without indexer =? manifest.verifiableStrategy.init(
    0, manifest.blocksCount - 1, manifest.numSlots).catch, err:
    trace "Unable to create indexing strategy from protected manifest", err = err.msg
    return failure(err)

  without blksIter =? indexer.getIndicies(slotIdx).catch, err:
    trace "Unable to get indicies from strategy", err = err.msg
    return failure(err)

  if err =? (await self.fetchBatched(
      manifest.treeCid,
      blksIter,
      onBatch = updateExpiry)).errorOption:
    trace "Unable to fetch blocks", err = err.msg
    return failure(err)

  without slotRoot =? (await builder.buildSlot(slotIdx.Natural)), err:
    trace "Unable to build slot", err = err.msg
    return failure(err)

  trace "Slot successfully retrieved and reconstructed"

  if cid =? slotRoot.toSlotCid() and cid != manifest.slotRoots[slotIdx.int]:
    trace "Slot root mismatch", manifest = manifest.slotRoots[slotIdx.int], recovered = slotRoot.toSlotCid()
    return failure(newException(CodexError, "Slot root mismatch"))

  trace "Slot successfully retrieved and reconstructed"

  return success()

proc onProve(
  self: CodexNodeRef,
  slot: Slot,
  challenge: ProofChallenge): Future[?!Groth16Proof] {.async.} =
  ## Generats a proof for a given slot and challenge
  ##

  let
    cidStr = slot.request.content.cid
    slotIdx = slot.slotIndex.truncate(Natural)

  logScope:
    cid = cidStr
    slot = slotIdx
    challenge = challenge

  trace "Received proof challenge"

  if prover =? self.prover:
    trace "Prover enabled"

    without cid =? Cid.init(cidStr).mapFailure, err:
      error "Unable to parse Cid", cid, err = err.msg
      return failure(err)

    without manifest =? await self.fetchManifest(cid), err:
      error "Unable to fetch manifest for cid", err = err.msg
      return failure(err)

    when defined(verify_circuit):
      without (inputs, proof) =? await prover.prove(slotIdx, manifest, challenge), err:
        error "Unable to generate proof", err = err.msg
        return failure(err)

      without checked =? await prover.verify(proof, inputs), err:
        error "Unable to verify proof", err = err.msg
        return failure(err)

      if not checked:
        error "Proof verification failed"
        return failure("Proof verification failed")

      trace "Proof verified successfully"
    else:
      without (_, proof) =? await prover.prove(slotIdx, manifest, challenge), err:
        error "Unable to generate proof", err = err.msg
        return failure(err)

    let groth16Proof = proof.toGroth16Proof()
    trace "Proof generated successfully", groth16Proof

    success groth16Proof
  else:
    warn "Prover not enabled"
    failure "Prover not enabled"

proc onExpiryUpdate(
  self: CodexNodeRef,
  rootCid: string,
  expiry: SecondsSince1970): Future[?!void] {.async.} =
  without cid =? Cid.init(rootCid):
    trace "Unable to parse Cid", cid
    let error = newException(CodexError, "Unable to parse Cid")
    return failure(error)

  return await self.updateExpiry(cid, expiry)

proc onClear(
  self: CodexNodeRef,
  request: StorageRequest,
  slotIndex: UInt256) =
# TODO: remove data from local storage
  discard

proc start*(self: CodexNodeRef) {.async.} =
  if not self.engine.isNil:
    await self.engine.start()

  if not self.discovery.isNil:
    await self.discovery.start()

  if not self.clock.isNil:
    await self.clock.start()

  if hostContracts =? self.contracts.host:
    hostContracts.sales.onStore =
      proc(
        request: StorageRequest,
        slot: UInt256,
        onBatch: BatchProc): Future[?!void] = self.onStore(request, slot, onBatch)

    hostContracts.sales.onExpiryUpdate =
      proc(rootCid: string, expiry: SecondsSince1970): Future[?!void] =
        self.onExpiryUpdate(rootCid, expiry)

    hostContracts.sales.onClear =
      proc(request: StorageRequest, slotIndex: UInt256) =
      # TODO: remove data from local storage
      self.onClear(request, slotIndex)

    hostContracts.sales.onProve =
      proc(slot: Slot, challenge: ProofChallenge): Future[?!Groth16Proof] =
        # TODO: generate proof
        self.onProve(slot, challenge)

    try:
      await hostContracts.start()
    except CancelledError as error:
      raise error
    except CatchableError as error:
      error "Unable to start host contract interactions", error=error.msg
      self.contracts.host = HostInteractions.none

  if clientContracts =? self.contracts.client:
    try:
      await clientContracts.start()
    except CancelledError as error:
      raise error
    except CatchableError as error:
      error "Unable to start client contract interactions: ", error=error.msg
      self.contracts.client = ClientInteractions.none

  if validatorContracts =? self.contracts.validator:
    try:
      await validatorContracts.start()
    except CancelledError as error:
      raise error
    except CatchableError as error:
      error "Unable to start validator contract interactions: ", error=error.msg
      self.contracts.validator = ValidatorInteractions.none

  self.networkId = self.switch.peerInfo.peerId
  notice "Started codex node", id = self.networkId, addrs = self.switch.peerInfo.addrs

proc stop*(self: CodexNodeRef) {.async.} =
  trace "Stopping node"

  if not self.engine.isNil:
    await self.engine.stop()

  if not self.discovery.isNil:
    await self.discovery.stop()

  if clientContracts =? self.contracts.client:
    await clientContracts.stop()

  if hostContracts =? self.contracts.host:
    await hostContracts.stop()

  if not self.clock.isNil:
    await self.clock.stop()

  if validatorContracts =? self.contracts.validator:
    await validatorContracts.stop()

  if not self.networkStore.isNil:
    await self.networkStore.close

proc new*(
  T: type CodexNodeRef,
  switch: Switch,
  networkStore: NetworkStore,
  engine: BlockExcEngine,
  discovery: Discovery,
  prover = Prover.none,
  contracts = Contracts.default,
  taskpool = Taskpool.new(num_threads = countProcessors())): CodexNodeRef =
  ## Create new instance of a Codex self, call `start` to run it
  ##

  CodexNodeRef(
    switch: switch,
    networkStore: networkStore,
    engine: engine,
    prover: prover,
    discovery: discovery,
    contracts: contracts,
    taskpool: taskpool)
