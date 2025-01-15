import std/tables
import pkg/stint
import pkg/chronos
import pkg/questionable
import pkg/nimcrypto
import ./market
import ./clock
import ./purchasing/purchase

export questionable
export chronos
export market
export purchase

type
  Purchasing* = ref object
    market: Market
    clock: Clock
    purchases: Table[PurchaseId, Purchase]
    proofProbability*: UInt256

  PurchaseTimeout* = Timeout

const DefaultProofProbability = 100.u256

proc new*(_: type Purchasing, market: Market, clock: Clock): Purchasing =
  Purchasing(market: market, clock: clock, proofProbability: DefaultProofProbability)

proc load*(purchasing: Purchasing) {.async.} =
  let market = purchasing.market
  let requestIds = await market.myRequests()
  for requestId in requestIds:
    let purchase = Purchase.new(requestId, purchasing.market, purchasing.clock)
    purchase.load()
    purchasing.purchases[purchase.id] = purchase

proc start*(purchasing: Purchasing) {.async.} =
  await purchasing.load()

proc stop*(purchasing: Purchasing) {.async.} =
  discard

proc populate*(
    purchasing: Purchasing, request: StorageRequest
): Future[StorageRequest] {.async.} =
  result = request
  if result.ask.proofProbability == 0.u256:
    result.ask.proofProbability = purchasing.proofProbability
  if result.nonce == Nonce.default:
    var id = result.nonce.toArray
    doAssert randomBytes(id) == 32
    result.nonce = Nonce(id)
  result.client = await purchasing.market.getSigner()

proc purchase*(
    purchasing: Purchasing, request: StorageRequest
): Future[Purchase] {.async.} =
  let request = await purchasing.populate(request)
  let purchase = Purchase.new(request, purchasing.market, purchasing.clock)
  purchase.start()
  purchasing.purchases[purchase.id] = purchase
  return purchase

func getPurchase*(purchasing: Purchasing, id: PurchaseId): ?Purchase =
  if purchasing.purchases.hasKey(id):
    some purchasing.purchases[id]
  else:
    none Purchase

func getPurchaseIds*(purchasing: Purchasing): seq[PurchaseId] =
  var pIds: seq[PurchaseId] = @[]
  for key in purchasing.purchases.keys:
    pIds.add(key)
  return pIds
