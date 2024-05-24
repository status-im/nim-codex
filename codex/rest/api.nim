## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}


import std/sequtils

import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/presto except toJson
import pkg/metrics except toJson
import pkg/stew/base10
import pkg/stew/byteutils
import pkg/confutils

import pkg/libp2p
import pkg/libp2p/routing_record
import pkg/codexdht/discv5/spr as spr

import ../logutils
import ../node
import ../blocktype
import ../conf
import ../contracts
import ../manifest
import ../streams/asyncstreamwrapper
import ../stores
import ../utils/options

import ./coders
import ./json

logScope:
  topics = "codex restapi"

declareCounter(codex_api_uploads, "codex API uploads")
declareCounter(codex_api_downloads, "codex API downloads")

proc getLongestRequestEnd(node: CodexNodeRef, availabilityId: AvailabilityId): ?!SecondsSince1970 =
  without contracts =? node.contracts.host:
    return failure("Sales unavailable")

  let
    reservations = contracts.sales.context.reservations
    market = contracts.sales.context.market
    requestEndFutures = reservations.all(Reservation, availabilityId).mapIt(market.getRequestEnd(it.requestId))

  if len(requestEndFutures) == 0:
    return success(0)

  try:
    let requestEnds = await allFutures(requestEndFutures)

    return success(requestEnds.reduce(max))
  except CancelledError as exc:
      raise exc
  except CatchableError as exc:
      return failure(exc.msg)

proc validate(
  pattern: string,
  value: string): int
  {.gcsafe, raises: [Defect].} =
  0

proc formatManifestBlocks(node: CodexNodeRef): Future[JsonNode] {.async.} =
  var content: seq[RestContent]

  proc formatManifest(cid: Cid, manifest: Manifest) =
    let restContent = RestContent.init(cid, manifest)
    content.add(restContent)

  await node.iterateManifests(formatManifest)
  return %RestContentList.init(content)

proc retrieveCid(
  node: CodexNodeRef,
  cid: Cid,
  local: bool = true,
  resp: HttpResponseRef): Future[RestApiResponse] {.async.} =
  ## Download a file from the node in a streaming
  ## manner
  ##

  var
    stream: LPStream

  var bytes = 0
  try:
    without stream =? (await node.retrieve(cid, local)), error:
      if error of BlockNotFoundError:
        return RestApiResponse.error(Http404, error.msg)
      else:
        return RestApiResponse.error(Http500, error.msg)

    resp.addHeader("Content-Type", "application/octet-stream")
    await resp.prepareChunked()

    while not stream.atEof:
      var
        buff = newSeqUninitialized[byte](DefaultBlockSize.int)
        len = await stream.readOnce(addr buff[0], buff.len)

      buff.setLen(len)
      if buff.len <= 0:
        break

      bytes += buff.len
      await resp.sendChunk(addr buff[0], buff.len)
    await resp.finish()
    codex_api_downloads.inc()
  except CatchableError as exc:
    warn "Excepting streaming blocks", exc = exc.msg
    return RestApiResponse.error(Http500)
  finally:
    info "Sent bytes", cid = cid, bytes
    if not stream.isNil:
      await stream.close()

proc initDataApi(node: CodexNodeRef, repoStore: RepoStore, router: var RestRouter) =
  router.rawApi(
    MethodPost,
    "/api/codex/v1/data") do (
    ) -> RestApiResponse:
      ## Upload a file in a streaming manner
      ##

      trace "Handling file upload"
      var bodyReader = request.getBodyReader()
      if bodyReader.isErr():
        return RestApiResponse.error(Http500)

      # Attempt to handle `Expect` header
      # some clients (curl), wait 1000ms
      # before giving up
      #
      await request.handleExpect()

      let
        reader = bodyReader.get()

      try:
        without cid =? (
          await node.store(AsyncStreamWrapper.new(reader = AsyncStreamReader(reader)))), error:
          trace "Error uploading file", exc = error.msg
          return RestApiResponse.error(Http500, error.msg)

        codex_api_uploads.inc()
        trace "Uploaded file", cid
        return RestApiResponse.response($cid)
      except CancelledError:
        trace "Upload cancelled error"
        return RestApiResponse.error(Http500)
      except AsyncStreamError:
        trace "Async stream error"
        return RestApiResponse.error(Http500)
      finally:
        await reader.closeWait()

      trace "Something went wrong error"
      return RestApiResponse.error(Http500)

  router.api(
    MethodGet,
    "/api/codex/v1/data") do () -> RestApiResponse:
      let json = await formatManifestBlocks(node)
      return RestApiResponse.response($json, contentType="application/json")

  router.api(
    MethodGet,
    "/api/codex/v1/data/{cid}") do (
      cid: Cid, resp: HttpResponseRef) -> RestApiResponse:
      ## Download a file from the local node in a streaming
      ## manner
      if cid.isErr:
        return RestApiResponse.error(
          Http400,
          $cid.error())

      await node.retrieveCid(cid.get(), local = true, resp=resp)

  router.api(
    MethodGet,
    "/api/codex/v1/data/{cid}/network") do (
      cid: Cid, resp: HttpResponseRef) -> RestApiResponse:
      ## Download a file from the network in a streaming
      ## manner
      ##

      if cid.isErr:
        return RestApiResponse.error(
          Http400,
          $cid.error())

      await node.retrieveCid(cid.get(), local = false, resp=resp)

  router.api(
    MethodGet,
    "/api/codex/v1/space") do () -> RestApiResponse:
      let json = % RestRepoStore(
        totalBlocks: repoStore.totalBlocks,
        quotaMaxBytes: repoStore.quotaMaxBytes,
        quotaUsedBytes: repoStore.quotaUsedBytes,
        quotaReservedBytes: repoStore.quotaReservedBytes
      )
      return RestApiResponse.response($json, contentType="application/json")

proc initSalesApi(node: CodexNodeRef, router: var RestRouter) =
  router.api(
    MethodGet,
    "/api/codex/v1/sales/slots") do () -> RestApiResponse:
      ## Returns active slots for the host
      try:
        without contracts =? node.contracts.host:
          return RestApiResponse.error(Http503, "Sales unavailable")

        let json = %(await contracts.sales.mySlots())
        return RestApiResponse.response($json, contentType="application/json")
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

  router.api(
    MethodGet,
    "/api/codex/v1/sales/slots/{slotId}") do (slotId: SlotId) -> RestApiResponse:
      ## Returns active slot with id {slotId} for the host. Returns 404 if the
      ## slot is not active for the host.

      without contracts =? node.contracts.host:
        return RestApiResponse.error(Http503, "Sales unavailable")

      without slotId =? slotId.tryGet.catch, error:
        return RestApiResponse.error(Http400, error.msg)

      without agent =? await contracts.sales.activeSale(slotId):
        return RestApiResponse.error(Http404, "Provider not filling slot")

      let restAgent = RestSalesAgent(
        state: agent.state() |? "none",
        slotIndex: agent.data.slotIndex,
        requestId: agent.data.requestId
      )

      return RestApiResponse.response(restAgent.toJson, contentType="application/json")

  router.api(
    MethodGet,
    "/api/codex/v1/sales/availability") do () -> RestApiResponse:
      ## Returns storage that is for sale

      try:
        without contracts =? node.contracts.host:
          return RestApiResponse.error(Http503, "Sales unavailable")

        without avails =? (await contracts.sales.context.reservations.all(Availability)), err:
          return RestApiResponse.error(Http500, err.msg)

        let json = %avails
        return RestApiResponse.response($json, contentType="application/json")
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

  router.rawApi(
    MethodPost,
    "/api/codex/v1/sales/availability") do () -> RestApiResponse:
      ## Add available storage to sell.
      ## Every time Availability's offer finishes, its capacity is returned to the availability.
      ##
      ## totalSize      - size of available storage in bytes
      ## duration       - maximum time the storage should be sold for (in seconds)
      ## minPrice       - minimum price to be paid (in amount of tokens)
      ## maxCollateral  - maximum collateral user is willing to pay per filled Slot (in amount of tokens)

      try:
        without contracts =? node.contracts.host:
          return RestApiResponse.error(Http503, "Sales unavailable")

        let body = await request.getBody()

        without restAv =? RestAvailability.fromJson(body), error:
          return RestApiResponse.error(Http400, error.msg)

        let reservations = contracts.sales.context.reservations

        if restAv.totalSize == 0:
          return RestApiResponse.error(Http400, "Total size must be larger then zero")

        if restAv.until < 0:
          return RestApiResponse.error(Http400, "Until parameter has to be positive integer")

        if not reservations.hasAvailable(restAv.totalSize.truncate(uint)):
          return RestApiResponse.error(Http422, "Not enough storage quota")

        without availability =? (
          await reservations.createAvailability(
            restAv.totalSize,
            restAv.duration,
            restAv.minPrice,
            restAv.maxCollateral,
            restAv.until,
            restAv.enabled |? true)
          ), error:
          return RestApiResponse.error(Http500, error.msg)

        return RestApiResponse.response(availability.toJson,
                                        Http201,
                                        contentType="application/json")
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

  router.rawApi(
    MethodPatch,
    "/api/codex/v1/sales/availability/{id}") do (id: AvailabilityId) -> RestApiResponse:
      ## Updates Availability.
      ## The new parameters will be only considered for new requests.
      ## Existing Requests linked to this Availability will continue as is.
      ##
      ## totalSize      - size of available storage in bytes. When decreasing the size, then lower limit is the currently `totalSize - freeSize`.
      ## duration       - maximum time the storage should be sold for (in seconds)
      ## minPrice       - minimum price to be paid (in amount of tokens)
      ## maxCollateral  - maximum collateral user is willing to pay per filled Slot (in amount of tokens)

      try:
        without contracts =? node.contracts.host:
          return RestApiResponse.error(Http503, "Sales unavailable")

        without id =? id.tryGet.catch, error:
          return RestApiResponse.error(Http400, error.msg)
        without keyId =? id.key.tryGet.catch, error:
          return RestApiResponse.error(Http400, error.msg)

        let
          body = await request.getBody()
          reservations = contracts.sales.context.reservations

        type OptRestAvailability = Optionalize(RestAvailability)
        without restAv =? OptRestAvailability.fromJson(body), error:
          return RestApiResponse.error(Http400, error.msg)

        without availability =? (await reservations.get(keyId, Availability)), error:
          if error of NotExistsError:
            return RestApiResponse.error(Http404, "Availability not found")

          return RestApiResponse.error(Http500, error.msg)

        if isSome restAv.freeSize:
          return RestApiResponse.error(Http400, "Updating freeSize is not allowed")

        if size =? restAv.totalSize:
          # we don't allow lowering the totalSize bellow currently utilized size
          if size < (availability.totalSize - availability.freeSize):
            return RestApiResponse.error(Http400, "New totalSize must be larger then current totalSize - freeSize, which is currently: " & $(availability.totalSize - availability.freeSize))

          availability.freeSize += size - availability.totalSize
          availability.totalSize = size

        if duration =? restAv.duration:
          availability.duration = duration

        if minPrice =? restAv.minPrice:
          availability.minPrice = minPrice

        if maxCollateral =? restAv.maxCollateral:
          availability.maxCollateral = maxCollateral

        if enabled =? restAv.enabled:
          availability.enabled = enabled

        if until =? restAv.until:
          if until < 0:
            return RestApiResponse.error(Http400, "Until parameter must be greater or equal 0. Got: " & $until)

          let longestRequestEnd = node.getLongestRequestEnd(id)
          if until != 0 && until < longestRequestEnd:
            return RestApiResponse.error(Http400, "Until parameter must be greater or equal the current longest request. Longest request ends at: " & $longestRequestEnd)

          availability.until = until

        if err =? (await reservations.update(availability)).errorOption:
          return RestApiResponse.error(Http500, err.msg)

        return RestApiResponse.response(Http200)
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

  router.rawApi(
    MethodGet,
    "/api/codex/v1/sales/availability/{id}/reservations") do (id: AvailabilityId) -> RestApiResponse:
      ## Gets Availability's reservations.

      try:
        without contracts =? node.contracts.host:
          return RestApiResponse.error(Http503, "Sales unavailable")

        without id =? id.tryGet.catch, error:
          return RestApiResponse.error(Http400, error.msg)
        without keyId =? id.key.tryGet.catch, error:
          return RestApiResponse.error(Http400, error.msg)

        let reservations = contracts.sales.context.reservations

        if error =? (await reservations.get(keyId, Availability)).errorOption:
          if error of NotExistsError:
            return RestApiResponse.error(Http404, "Availability not found")
          else:
            return RestApiResponse.error(Http500, error.msg)

        without availabilitysReservations =? (await reservations.all(Reservation, id)), err:
          return RestApiResponse.error(Http500, err.msg)

        # TODO: Expand this structure with information about the linked StorageRequest not only RequestID
        return RestApiResponse.response(availabilitysReservations.toJson, contentType="application/json")
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

proc initPurchasingApi(node: CodexNodeRef, router: var RestRouter) =
  router.rawApi(
    MethodPost,
    "/api/codex/v1/storage/request/{cid}") do (cid: Cid) -> RestApiResponse:
      ## Create a request for storage
      ##
      ## cid              - the cid of a previously uploaded dataset
      ## duration         - the duration of the request in seconds
      ## proofProbability - how often storage proofs are required
      ## reward           - the maximum amount of tokens paid per second per slot to hosts the client is willing to pay
      ## expiry           - specifies threshold in seconds from now when the request expires if the Request does not find requested amount of nodes to host the data
      ## nodes            - number of nodes the content should be stored on
      ## tolerance        - allowed number of nodes that can be lost before content is lost
      ## colateral        - requested collateral from hosts when they fill slot

      try:
        without contracts =? node.contracts.client:
          return RestApiResponse.error(Http503, "Purchasing unavailable")

        without cid =? cid.tryGet.catch, error:
          return RestApiResponse.error(Http400, error.msg)

        let body = await request.getBody()

        without params =? StorageRequestParams.fromJson(body), error:
          return RestApiResponse.error(Http400, error.msg)

        let nodes = params.nodes |? 1
        let tolerance = params.tolerance |? 0

        if (nodes - tolerance) < 1:
          return RestApiResponse.error(Http400, "Tolerance cannot be greater or equal than nodes (nodes - tolerance)")

        without expiry =? params.expiry:
          return RestApiResponse.error(Http400, "Expiry required")

        if expiry <= 0 or expiry >= params.duration:
          return RestApiResponse.error(Http400, "Expiry needs value bigger then zero and smaller then the request's duration")

        without purchaseId =? await node.requestStorage(
          cid,
          params.duration,
          params.proofProbability,
          nodes,
          tolerance,
          params.reward,
          params.collateral,
          expiry), error:

          return RestApiResponse.error(Http500, error.msg)

        return RestApiResponse.response(purchaseId.toHex)
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

  router.api(
    MethodGet,
    "/api/codex/v1/storage/purchases/{id}") do (
      id: PurchaseId) -> RestApiResponse:

      try:
        without contracts =? node.contracts.client:
          return RestApiResponse.error(Http503, "Purchasing unavailable")

        without id =? id.tryGet.catch, error:
          return RestApiResponse.error(Http400, error.msg)

        without purchase =? contracts.purchasing.getPurchase(id):
          return RestApiResponse.error(Http404)

        let json = % RestPurchase(
          state: purchase.state |? "none",
          error: purchase.error.?msg,
          request: purchase.request,
          requestId: purchase.requestId
        )

        return RestApiResponse.response($json, contentType="application/json")
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

  router.api(
    MethodGet,
    "/api/codex/v1/storage/purchases") do () -> RestApiResponse:
      try:
        without contracts =? node.contracts.client:
          return RestApiResponse.error(Http503, "Purchasing unavailable")

        let purchaseIds = contracts.purchasing.getPurchaseIds()
        return RestApiResponse.response($ %purchaseIds, contentType="application/json")
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

proc initNodeApi(node: CodexNodeRef, conf: CodexConf, router: var RestRouter) =
  ## various node management api's
  ##
  router.api(
    MethodGet,
    "/api/codex/v1/spr") do () -> RestApiResponse:
      ## Returns node SPR in requested format, json or text.
      ##
      try:
        without spr =? node.discovery.dhtRecord:
          return RestApiResponse.response("", status=Http503, contentType="application/json")

        if $preferredContentType().get() == "text/plain":
            return RestApiResponse.response(spr.toURI, contentType="text/plain")
        else:
            return RestApiResponse.response($ %* {"spr": spr.toURI}, contentType="application/json")
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

  router.api(
    MethodGet,
    "/api/codex/v1/peerid") do () -> RestApiResponse:
      ## Returns node's peerId in requested format, json or text.
      ##
      try:
        let id = $node.switch.peerInfo.peerId

        if $preferredContentType().get() == "text/plain":
            return RestApiResponse.response(id, contentType="text/plain")
        else:
            return RestApiResponse.response($ %* {"id": id}, contentType="application/json")
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

  router.api(
    MethodGet,
    "/api/codex/v1/connect/{peerId}") do (
      peerId: PeerId,
      addrs: seq[MultiAddress]) -> RestApiResponse:
      ## Connect to a peer
      ##
      ## If `addrs` param is supplied, it will be used to
      ## dial the peer, otherwise the `peerId` is used
      ## to invoke peer discovery, if it succeeds
      ## the returned addresses will be used to dial
      ##
      ## `addrs` the listening addresses of the peers to dial, eg the one specified with `--listen-addrs`
      ##

      if peerId.isErr:
        return RestApiResponse.error(
          Http400,
          $peerId.error())

      let addresses = if addrs.isOk and addrs.get().len > 0:
            addrs.get()
          else:
            without peerRecord =? (await node.findPeer(peerId.get())):
              return RestApiResponse.error(
                Http400,
                "Unable to find Peer!")
            peerRecord.addresses.mapIt(it.address)
      try:
        await node.connect(peerId.get(), addresses)
        return RestApiResponse.response("Successfully connected to peer")
      except DialFailedError:
        return RestApiResponse.error(Http400, "Unable to dial peer")
      except CatchableError:
        return RestApiResponse.error(Http500, "Unknown error dialling peer")

proc initDebugApi(node: CodexNodeRef, conf: CodexConf, router: var RestRouter) =
  router.api(
    MethodGet,
    "/api/codex/v1/debug/info") do () -> RestApiResponse:
      ## Print rudimentary node information
      ##

      try:
        let table = RestRoutingTable.init(node.discovery.protocol.routingTable)

        let
          json = %*{
            "id": $node.switch.peerInfo.peerId,
            "addrs": node.switch.peerInfo.addrs.mapIt( $it ),
            "repo": $conf.dataDir,
            "spr":
              if node.discovery.dhtRecord.isSome:
                node.discovery.dhtRecord.get.toURI
              else:
                "",
            "announceAddresses": node.discovery.announceAddrs,
            "table": table,
            "codex": {
              "version": $codexVersion,
              "revision": $codexRevision
            }
          }

        # return pretty json for human readability
        return RestApiResponse.response(json.pretty(), contentType="application/json")
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

  router.api(
    MethodPost,
    "/api/codex/v1/debug/chronicles/loglevel") do (
      level: Option[string]) -> RestApiResponse:
      ## Set log level at run time
      ##
      ## e.g. `chronicles/loglevel?level=DEBUG`
      ##
      ## `level` - chronicles log level
      ##

      try:
        without res =? level and level =? res:
          return RestApiResponse.error(Http400, "Missing log level")

        try:
          {.gcsafe.}:
            updateLogLevel(level)
        except CatchableError as exc:
          return RestApiResponse.error(Http500, exc.msg)

        return RestApiResponse.response("")
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

  when codex_enable_api_debug_peers:
    router.api(
      MethodGet,
      "/api/codex/v1/debug/peer/{peerId}") do (peerId: PeerId) -> RestApiResponse:

      try:
        trace "debug/peer start"
        without peerRecord =? (await node.findPeer(peerId.get())):
          trace "debug/peer peer not found!"
          return RestApiResponse.error(
            Http400,
            "Unable to find Peer!")

        let json = %RestPeerRecord.init(peerRecord)
        trace "debug/peer returning peer record"
        return RestApiResponse.response($json)
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500)

proc initRestApi*(node: CodexNodeRef, conf: CodexConf, repoStore: RepoStore): RestRouter =
  var router = RestRouter.init(validate)

  initDataApi(node, repoStore, router)
  initSalesApi(node, router)
  initPurchasingApi(node, router)
  initNodeApi(node, conf, router)
  initDebugApi(node, conf, router)

  return router
