import std/httpclient
import std/strutils

from pkg/libp2p import Cid, `$`, init
import pkg/stint
import pkg/questionable/results
import pkg/chronos/apps/http/[httpserver, shttpserver, httpclient]
import pkg/codex/logutils
import pkg/codex/rest/json
import pkg/codex/purchasing
import pkg/codex/errors
import pkg/codex/sales/reservations

export purchasing

type CodexClient* = ref object
  http: HttpClient
  baseurl: string
  session: HttpSessionRef

type CodexClientError* = object of CatchableError

const HttpClientTimeoutMs = 60 * 1000

proc new*(_: type CodexClient, baseurl: string): CodexClient =
  CodexClient(
    http: newHttpClient(timeout=HttpClientTimeoutMs),
    baseurl: baseurl,
    session: HttpSessionRef.new({HttpClientFlag.Http11Pipeline})
  )

proc info*(client: CodexClient): ?!JsonNode =
  let url = client.baseurl & "/debug/info"
  JsonNode.parse( client.http.getContent(url) )

proc setLogLevel*(client: CodexClient, level: string) =
  let url = client.baseurl & "/debug/chronicles/loglevel?level=" & level
  let headers = newHttpHeaders({"Content-Type": "text/plain"})
  let response = client.http.request(url, httpMethod=HttpPost, headers=headers)
  assert response.status == "200 OK"

proc upload*(client: CodexClient, contents: string): ?!Cid =
  let response = client.http.post(client.baseurl & "/data", contents)
  assert response.status == "200 OK"
  Cid.init(response.body).mapFailure

proc download*(client: CodexClient, cid: Cid, local = false): ?!string =
  let
    response = client.http.get(
      client.baseurl & "/data/" & $cid &
      (if local: "" else: "/network/stream"))

  if response.status != "200 OK":
    return failure(response.status)

  success response.body

proc downloadManifestOnly*(client: CodexClient, cid: Cid): ?!string =
  let
    response = client.http.get(
      client.baseurl & "/data/" & $cid & "/network/manifest")

  if response.status != "200 OK":
    return failure(response.status)

  success response.body

proc downloadNoStream*(client: CodexClient, cid: Cid): ?!string =
  let
    response = client.http.post(
      client.baseurl & "/data/" & $cid & "/network")

  if response.status != "200 OK":
    return failure(response.status)

  success response.body

proc downloadBytes*(
  client: CodexClient,
  cid: Cid,
  local = false): Future[?!seq[byte]] {.async.} =

  let uri = parseUri(
    client.baseurl & "/data/" & $cid &
    (if local: "" else: "/network/stream")
  )

  let (status, bytes) = await client.session.fetch(uri)

  if status != 200:
    return failure("fetch failed with status " & $status)

  success bytes

proc list*(client: CodexClient): ?!RestContentList =
  let url = client.baseurl & "/data"
  let response = client.http.get(url)

  if response.status != "200 OK":
    return failure(response.status)

  RestContentList.fromJson(response.body)

proc space*(client: CodexClient): ?!RestRepoStore =
  let url = client.baseurl & "/space"
  let response = client.http.get(url)

  if response.status != "200 OK":
    return failure(response.status)

  RestRepoStore.fromJson(response.body)

proc requestStorageRaw*(
    client: CodexClient,
    cid: Cid,
    duration: UInt256,
    pricePerBytePerSecond: UInt256,
    proofProbability: UInt256,
    collateralPerByte: UInt256,
    expiry: uint = 0,
    nodes: uint = 3,
    tolerance: uint = 1
): Response =

  ## Call request storage REST endpoint
  ##
  let url = client.baseurl & "/storage/request/" & $cid
  let json = %*{
      "duration": duration,
      "pricePerBytePerSecond": pricePerBytePerSecond,
      "proofProbability": proofProbability,
      "collateralPerByte": collateralPerByte,
      "nodes": nodes,
      "tolerance": tolerance
    }

  if expiry != 0:
    json["expiry"] = %($expiry)

  return client.http.post(url, $json)

proc requestStorage*(
    client: CodexClient,
    cid: Cid,
    duration: UInt256,
    pricePerBytePerSecond: UInt256,
    proofProbability: UInt256,
    expiry: uint,
    collateralPerByte: UInt256,
    nodes: uint = 3,
    tolerance: uint = 1
): ?!PurchaseId =
  ## Call request storage REST endpoint
  ##
  let response = client.requestStorageRaw(cid, duration, 
    pricePerBytePerSecond, proofProbability, collateralPerByte,
    expiry, nodes, tolerance)
  if response.status != "200 OK":
    doAssert(false, response.body)
  PurchaseId.fromHex(response.body).catch

proc getPurchase*(client: CodexClient, purchaseId: PurchaseId): ?!RestPurchase =
  let url = client.baseurl & "/storage/purchases/" & purchaseId.toHex
  try:
    let body = client.http.getContent(url)
    return RestPurchase.fromJson(body)
  except CatchableError as e:
    return failure e.msg

proc getSalesAgent*(client: CodexClient, slotId: SlotId): ?!RestSalesAgent =
  let url = client.baseurl & "/sales/slots/" & slotId.toHex
  try:
    let body = client.http.getContent(url)
    return RestSalesAgent.fromJson(body)
  except CatchableError as e:
    return failure e.msg

proc getSlots*(client: CodexClient): ?!seq[Slot] =
  let url = client.baseurl & "/sales/slots"
  let body = client.http.getContent(url)
  seq[Slot].fromJson(body)

proc postAvailability*(
    client: CodexClient,
    totalSize, duration, minPrice, maxCollateral: UInt256
): ?!Availability =
  ## Post sales availability endpoint
  ##
  let url = client.baseurl & "/sales/availability"
  let json = %*{
    "totalSize": totalSize,
    "duration": duration,
    "minPrice": minPrice,
    "maxCollateral": maxCollateral,
  }
  let response = client.http.post(url, $json)
  doAssert response.status == "201 Created", "expected 201 Created, got " & response.status & ", body: " & response.body
  Availability.fromJson(response.body)

proc patchAvailabilityRaw*(
    client: CodexClient,
    availabilityId: AvailabilityId,
    totalSize, freeSize, duration, minPrice, maxCollateral: ?UInt256 = UInt256.none
): Response =
  ## Updates availability
  ##
  let url = client.baseurl & "/sales/availability/" & $availabilityId

  # TODO: Optionalize macro does not keep `serialize` pragmas so we can't use `Optionalize(RestAvailability)` here.
  var json = %*{}

  if totalSize =? totalSize:
    json["totalSize"] = %totalSize

  if freeSize =? freeSize:
    json["freeSize"] = %freeSize

  if duration =? duration:
    json["duration"] = %duration

  if minPrice =? minPrice:
    json["minPrice"] = %minPrice

  if maxCollateral =? maxCollateral:
    json["maxCollateral"] = %maxCollateral

  client.http.patch(url, $json)

proc patchAvailability*(
    client: CodexClient,
    availabilityId: AvailabilityId,
    totalSize, duration, minPrice, maxCollateral: ?UInt256 = UInt256.none
): void =
  let response = client.patchAvailabilityRaw(availabilityId, totalSize=totalSize, duration=duration, minPrice=minPrice, maxCollateral=maxCollateral)
  doAssert response.status == "200 OK", "expected 200 OK, got " & response.status

proc getAvailabilities*(client: CodexClient): ?!seq[Availability] =
  ## Call sales availability REST endpoint
  let url = client.baseurl & "/sales/availability"
  let body = client.http.getContent(url)
  seq[Availability].fromJson(body)

proc getAvailabilityReservations*(client: CodexClient, availabilityId: AvailabilityId): ?!seq[Reservation] =
  ## Retrieves Availability's Reservations
  let url = client.baseurl & "/sales/availability/" & $availabilityId & "/reservations"
  let body = client.http.getContent(url)
  seq[Reservation].fromJson(body)

proc close*(client: CodexClient) =
  client.http.close()

proc restart*(client: CodexClient) =
  client.http.close()
  client.http = newHttpClient(timeout=HttpClientTimeoutMs)

proc purchaseStateIs*(client: CodexClient, id: PurchaseId, state: string): bool =
  client.getPurchase(id).option.?state == some state

proc saleStateIs*(client: CodexClient, id: SlotId, state: string): bool =
  client.getSalesAgent(id).option.?state == some state

proc requestId*(client: CodexClient, id: PurchaseId): ?RequestId =
  return client.getPurchase(id).option.?requestId

proc uploadRaw*(client: CodexClient, contents: string, headers = newHttpHeaders()): Response =
  return client.http.request(client.baseurl & "/data", body = contents, httpMethod=HttpPost, headers = headers)

proc listRaw*(client: CodexClient): Response =
  return client.http.request(client.baseurl & "/data", httpMethod=HttpGet)

proc downloadRaw*(client: CodexClient, cid: string, local = false): Response =
  return client.http.request(client.baseurl & "/data/" & cid &
      (if local: "" else: "/network/stream"), httpMethod=HttpGet)