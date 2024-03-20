import std/httpclient
import std/strutils

from pkg/libp2p import Cid, `$`, init
import pkg/stint
import pkg/questionable/results
import pkg/codex/logutils
import pkg/codex/rest/json
import pkg/codex/purchasing
import pkg/codex/errors
import pkg/codex/sales/reservations
import pkg/codex/utils/options

export purchasing

type CodexClient* = ref object
  http: HttpClient
  baseurl: string

proc new*(_: type CodexClient, baseurl: string): CodexClient =
  CodexClient(http: newHttpClient(), baseurl: baseurl)

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
      (if local: "" else: "/network"))

  if response.status != "200 OK":
    return failure(response.status)

  success response.body

proc list*(client: CodexClient): ?!seq[RestContent] =
  let url = client.baseurl & "/data"
  let response = client.http.get(url)

  if response.status != "200 OK":
    return failure(response.status)

  seq[RestContent].fromJson(response.body)

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
    reward: UInt256,
    proofProbability: UInt256,
    collateral: UInt256,
    expiry: UInt256 = 0.u256,
    nodes: uint = 1,
    tolerance: uint = 0
): Response =

  ## Call request storage REST endpoint
  ##
  let url = client.baseurl & "/storage/request/" & $cid
  let json = %*{
      "duration": duration,
      "reward": reward,
      "proofProbability": proofProbability,
      "collateral": collateral,
      "nodes": nodes,
      "tolerance": tolerance
    }

  if expiry != 0:
    json["expiry"] = %expiry

  return client.http.post(url, $json)

proc requestStorage*(
    client: CodexClient,
    cid: Cid,
    duration: UInt256,
    reward: UInt256,
    proofProbability: UInt256,
    expiry: UInt256,
    collateral: UInt256,
    nodes: uint = 1,
    tolerance: uint = 0
): ?!PurchaseId =
  ## Call request storage REST endpoint
  ##
  let response = client.requestStorageRaw(cid, duration, reward, proofProbability, collateral, expiry, nodes, tolerance)
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
  type OptRestAvailability = Optionalize(RestAvailability)
  let availability = OptRestAvailability(totalSize: totalSize, freeSize: freeSize, duration: duration, minPrice: minPrice, maxCollateral: maxCollateral)
  client.http.patch(url, availability.toJson)

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
  seq[Reservation].fromJson(parseJson(body))

proc close*(client: CodexClient) =
  client.http.close()

proc restart*(client: CodexClient) =
  client.http.close()
  client.http = newHttpClient()

proc purchaseStateIs*(client: CodexClient, id: PurchaseId, state: string): bool =
  client.getPurchase(id).option.?state == some state

proc saleStateIs*(client: CodexClient, id: SlotId, state: string): bool =
  client.getSalesAgent(id).option.?state == some state

proc requestId*(client: CodexClient, id: PurchaseId): ?RequestId =
  return client.getPurchase(id).option.?requestId
