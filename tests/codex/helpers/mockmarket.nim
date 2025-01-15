import std/sequtils
import std/tables
import std/hashes
import std/sets
import std/sugar
import pkg/questionable
import pkg/codex/market
import pkg/codex/contracts/requests
import pkg/codex/contracts/proofs
import pkg/codex/contracts/config

from pkg/ethers import BlockTag
import codex/clock

import ../examples

export market
export tables

logScope:
  topics = "mockMarket"

type
  MockMarket* = ref object of Market
    periodicity: Periodicity
    activeRequests*: Table[Address, seq[RequestId]]
    activeSlots*: Table[Address, seq[SlotId]]
    requested*: seq[StorageRequest]
    requestEnds*: Table[RequestId, SecondsSince1970]
    requestExpiry*: Table[RequestId, SecondsSince1970]
    requestState*: Table[RequestId, RequestState]
    slotState*: Table[SlotId, SlotState]
    fulfilled*: seq[Fulfillment]
    filled*: seq[MockSlot]
    freed*: seq[SlotId]
    submitted*: seq[Groth16Proof]
    markedAsMissingProofs*: seq[SlotId]
    canBeMarkedAsMissing: HashSet[SlotId]
    withdrawn*: seq[RequestId]
    proofPointer*: uint8
    proofsRequired: HashSet[SlotId]
    proofsToBeRequired: HashSet[SlotId]
    proofChallenge*: ProofChallenge
    proofEnds: Table[SlotId, UInt256]
    signer: Address
    subscriptions: Subscriptions
    config*: MarketplaceConfig
    canReserveSlot*: bool
    reserveSlotThrowError*: ?(ref MarketError)
    clock: ?Clock

  Fulfillment* = object
    requestId*: RequestId
    proof*: Groth16Proof
    host*: Address

  MockSlot* = object
    requestId*: RequestId
    host*: Address
    slotIndex*: UInt256
    proof*: Groth16Proof
    timestamp: ?SecondsSince1970

  Subscriptions = object
    onRequest: seq[RequestSubscription]
    onFulfillment: seq[FulfillmentSubscription]
    onSlotFilled: seq[SlotFilledSubscription]
    onSlotFreed: seq[SlotFreedSubscription]
    onSlotReservationsFull: seq[SlotReservationsFullSubscription]
    onRequestCancelled: seq[RequestCancelledSubscription]
    onRequestFailed: seq[RequestFailedSubscription]
    onProofSubmitted: seq[ProofSubmittedSubscription]

  RequestSubscription* = ref object of Subscription
    market: MockMarket
    callback: OnRequest

  FulfillmentSubscription* = ref object of Subscription
    market: MockMarket
    requestId: ?RequestId
    callback: OnFulfillment

  SlotFilledSubscription* = ref object of Subscription
    market: MockMarket
    requestId: ?RequestId
    slotIndex: ?UInt256
    callback: OnSlotFilled

  SlotFreedSubscription* = ref object of Subscription
    market: MockMarket
    callback: OnSlotFreed

  SlotReservationsFullSubscription* = ref object of Subscription
    market: MockMarket
    callback: OnSlotReservationsFull

  RequestCancelledSubscription* = ref object of Subscription
    market: MockMarket
    requestId: ?RequestId
    callback: OnRequestCancelled

  RequestFailedSubscription* = ref object of Subscription
    market: MockMarket
    requestId: ?RequestId
    callback: OnRequestCancelled

  ProofSubmittedSubscription = ref object of Subscription
    market: MockMarket
    callback: OnProofSubmitted

proc hash*(address: Address): Hash =
  hash(address.toArray)

proc hash*(requestId: RequestId): Hash =
  hash(requestId.toArray)

proc new*(_: type MockMarket, clock: ?Clock = Clock.none): MockMarket =
  ## Create a new mocked Market instance
  ##
  let config = MarketplaceConfig(
    collateral: CollateralConfig(
      repairRewardPercentage: 10,
      maxNumberOfSlashes: 5,
      slashCriterion: 3,
      slashPercentage: 10,
    ),
    proofs: ProofConfig(
      period: 10.u256, timeout: 5.u256, downtime: 64.uint8, downtimeProduct: 67.uint8
    ),
  )
  MockMarket(
    signer: Address.example, config: config, canReserveSlot: true, clock: clock
  )

method getSigner*(market: MockMarket): Future[Address] {.async.} =
  return market.signer

method periodicity*(mock: MockMarket): Future[Periodicity] {.async.} =
  return Periodicity(seconds: mock.config.proofs.period)

method proofTimeout*(market: MockMarket): Future[UInt256] {.async.} =
  return market.config.proofs.timeout

method proofDowntime*(market: MockMarket): Future[uint8] {.async.} =
  return market.config.proofs.downtime

method repairRewardPercentage*(market: MockMarket): Future[uint8] {.async.} =
  return market.config.collateral.repairRewardPercentage

method getPointer*(market: MockMarket, slotId: SlotId): Future[uint8] {.async.} =
  return market.proofPointer

method requestStorage*(market: MockMarket, request: StorageRequest) {.async.} =
  market.requested.add(request)
  var subscriptions = market.subscriptions.onRequest
  for subscription in subscriptions:
    subscription.callback(request.id, request.ask, request.expiry)

method myRequests*(market: MockMarket): Future[seq[RequestId]] {.async.} =
  return market.activeRequests[market.signer]

method mySlots*(market: MockMarket): Future[seq[SlotId]] {.async.} =
  return market.activeSlots[market.signer]

method getRequest*(
    market: MockMarket, id: RequestId
): Future[?StorageRequest] {.async.} =
  for request in market.requested:
    if request.id == id:
      return some request
  return none StorageRequest

method getActiveSlot*(market: MockMarket, slotId: SlotId): Future[?Slot] {.async.} =
  for slot in market.filled:
    if slotId(slot.requestId, slot.slotIndex) == slotId and
        request =? await market.getRequest(slot.requestId):
      return some Slot(request: request, slotIndex: slot.slotIndex)
  return none Slot

method requestState*(
    market: MockMarket, requestId: RequestId
): Future[?RequestState] {.async.} =
  return market.requestState .? [requestId]

method slotState*(market: MockMarket, slotId: SlotId): Future[SlotState] {.async.} =
  if not market.slotState.hasKey(slotId):
    return SlotState.Free
  return market.slotState[slotId]

method getRequestEnd*(
    market: MockMarket, id: RequestId
): Future[SecondsSince1970] {.async.} =
  return market.requestEnds[id]

method requestExpiresAt*(
    market: MockMarket, id: RequestId
): Future[SecondsSince1970] {.async.} =
  return market.requestExpiry[id]

method getHost*(
    market: MockMarket, requestId: RequestId, slotIndex: UInt256
): Future[?Address] {.async.} =
  for slot in market.filled:
    if slot.requestId == requestId and slot.slotIndex == slotIndex:
      return some slot.host
  return none Address

proc emitSlotFilled*(market: MockMarket, requestId: RequestId, slotIndex: UInt256) =
  var subscriptions = market.subscriptions.onSlotFilled
  for subscription in subscriptions:
    let requestMatches =
      subscription.requestId.isNone or subscription.requestId == some requestId
    let slotMatches =
      subscription.slotIndex.isNone or subscription.slotIndex == some slotIndex
    if requestMatches and slotMatches:
      subscription.callback(requestId, slotIndex)

proc emitSlotFreed*(market: MockMarket, requestId: RequestId, slotIndex: UInt256) =
  var subscriptions = market.subscriptions.onSlotFreed
  for subscription in subscriptions:
    subscription.callback(requestId, slotIndex)

proc emitSlotReservationsFull*(
    market: MockMarket, requestId: RequestId, slotIndex: UInt256
) =
  var subscriptions = market.subscriptions.onSlotReservationsFull
  for subscription in subscriptions:
    subscription.callback(requestId, slotIndex)

proc emitRequestCancelled*(market: MockMarket, requestId: RequestId) =
  var subscriptions = market.subscriptions.onRequestCancelled
  for subscription in subscriptions:
    if subscription.requestId == requestId.some or subscription.requestId.isNone:
      subscription.callback(requestId)

proc emitRequestFulfilled*(market: MockMarket, requestId: RequestId) =
  var subscriptions = market.subscriptions.onFulfillment
  for subscription in subscriptions:
    if subscription.requestId == requestId.some or subscription.requestId.isNone:
      subscription.callback(requestId)

proc emitRequestFailed*(market: MockMarket, requestId: RequestId) =
  var subscriptions = market.subscriptions.onRequestFailed
  for subscription in subscriptions:
    if subscription.requestId == requestId.some or subscription.requestId.isNone:
      subscription.callback(requestId)

proc fillSlot*(
    market: MockMarket,
    requestId: RequestId,
    slotIndex: UInt256,
    proof: Groth16Proof,
    host: Address,
) =
  let slot = MockSlot(
    requestId: requestId,
    slotIndex: slotIndex,
    proof: proof,
    host: host,
    timestamp: market.clock .? now,
  )
  market.filled.add(slot)
  market.slotState[slotId(slot.requestId, slot.slotIndex)] = SlotState.Filled
  market.emitSlotFilled(requestId, slotIndex)

method fillSlot*(
    market: MockMarket,
    requestId: RequestId,
    slotIndex: UInt256,
    proof: Groth16Proof,
    collateral: UInt256,
) {.async.} =
  market.fillSlot(requestId, slotIndex, proof, market.signer)

method freeSlot*(market: MockMarket, slotId: SlotId) {.async.} =
  market.freed.add(slotId)
  for s in market.filled:
    if slotId(s.requestId, s.slotIndex) == slotId:
      market.emitSlotFreed(s.requestId, s.slotIndex)
      break
  market.slotState[slotId] = SlotState.Free

method withdrawFunds*(market: MockMarket, requestId: RequestId) {.async.} =
  market.withdrawn.add(requestId)

  if state =? market.requestState .? [requestId] and state == RequestState.Cancelled:
    market.emitRequestCancelled(requestId)

proc setProofRequired*(mock: MockMarket, id: SlotId, required: bool) =
  if required:
    mock.proofsRequired.incl(id)
  else:
    mock.proofsRequired.excl(id)

method isProofRequired*(mock: MockMarket, id: SlotId): Future[bool] {.async.} =
  return mock.proofsRequired.contains(id)

proc setProofToBeRequired*(mock: MockMarket, id: SlotId, required: bool) =
  if required:
    mock.proofsToBeRequired.incl(id)
  else:
    mock.proofsToBeRequired.excl(id)

method willProofBeRequired*(mock: MockMarket, id: SlotId): Future[bool] {.async.} =
  return mock.proofsToBeRequired.contains(id)

method getChallenge*(mock: MockMarket, id: SlotId): Future[ProofChallenge] {.async.} =
  return mock.proofChallenge

proc setProofEnd*(mock: MockMarket, id: SlotId, proofEnd: UInt256) =
  mock.proofEnds[id] = proofEnd

method submitProof*(mock: MockMarket, id: SlotId, proof: Groth16Proof) {.async.} =
  mock.submitted.add(proof)
  for subscription in mock.subscriptions.onProofSubmitted:
    subscription.callback(id)

method markProofAsMissing*(market: MockMarket, id: SlotId, period: Period) {.async.} =
  market.markedAsMissingProofs.add(id)

proc setCanProofBeMarkedAsMissing*(mock: MockMarket, id: SlotId, required: bool) =
  if required:
    mock.canBeMarkedAsMissing.incl(id)
  else:
    mock.canBeMarkedAsMissing.excl(id)

method canProofBeMarkedAsMissing*(
    market: MockMarket, id: SlotId, period: Period
): Future[bool] {.async.} =
  return market.canBeMarkedAsMissing.contains(id)

method reserveSlot*(
    market: MockMarket, requestId: RequestId, slotIndex: UInt256
) {.async.} =
  if error =? market.reserveSlotThrowError:
    raise error

method canReserveSlot*(
    market: MockMarket, requestId: RequestId, slotIndex: UInt256
): Future[bool] {.async.} =
  return market.canReserveSlot

func setCanReserveSlot*(market: MockMarket, canReserveSlot: bool) =
  market.canReserveSlot = canReserveSlot

func setReserveSlotThrowError*(market: MockMarket, error: ?(ref MarketError)) =
  market.reserveSlotThrowError = error

method subscribeRequests*(
    market: MockMarket, callback: OnRequest
): Future[Subscription] {.async.} =
  let subscription = RequestSubscription(market: market, callback: callback)
  market.subscriptions.onRequest.add(subscription)
  return subscription

method subscribeFulfillment*(
    market: MockMarket, callback: OnFulfillment
): Future[Subscription] {.async.} =
  let subscription = FulfillmentSubscription(
    market: market, requestId: none RequestId, callback: callback
  )
  market.subscriptions.onFulfillment.add(subscription)
  return subscription

method subscribeFulfillment*(
    market: MockMarket, requestId: RequestId, callback: OnFulfillment
): Future[Subscription] {.async.} =
  let subscription = FulfillmentSubscription(
    market: market, requestId: some requestId, callback: callback
  )
  market.subscriptions.onFulfillment.add(subscription)
  return subscription

method subscribeSlotFilled*(
    market: MockMarket, callback: OnSlotFilled
): Future[Subscription] {.async.} =
  let subscription = SlotFilledSubscription(market: market, callback: callback)
  market.subscriptions.onSlotFilled.add(subscription)
  return subscription

method subscribeSlotFilled*(
    market: MockMarket, requestId: RequestId, slotIndex: UInt256, callback: OnSlotFilled
): Future[Subscription] {.async.} =
  let subscription = SlotFilledSubscription(
    market: market,
    requestId: some requestId,
    slotIndex: some slotIndex,
    callback: callback,
  )
  market.subscriptions.onSlotFilled.add(subscription)
  return subscription

method subscribeSlotFreed*(
    market: MockMarket, callback: OnSlotFreed
): Future[Subscription] {.async.} =
  let subscription = SlotFreedSubscription(market: market, callback: callback)
  market.subscriptions.onSlotFreed.add(subscription)
  return subscription

method subscribeSlotReservationsFull*(
    market: MockMarket, callback: OnSlotReservationsFull
): Future[Subscription] {.async.} =
  let subscription =
    SlotReservationsFullSubscription(market: market, callback: callback)
  market.subscriptions.onSlotReservationsFull.add(subscription)
  return subscription

method subscribeRequestCancelled*(
    market: MockMarket, callback: OnRequestCancelled
): Future[Subscription] {.async.} =
  let subscription = RequestCancelledSubscription(
    market: market, requestId: none RequestId, callback: callback
  )
  market.subscriptions.onRequestCancelled.add(subscription)
  return subscription

method subscribeRequestCancelled*(
    market: MockMarket, requestId: RequestId, callback: OnRequestCancelled
): Future[Subscription] {.async.} =
  let subscription = RequestCancelledSubscription(
    market: market, requestId: some requestId, callback: callback
  )
  market.subscriptions.onRequestCancelled.add(subscription)
  return subscription

method subscribeRequestFailed*(
    market: MockMarket, callback: OnRequestFailed
): Future[Subscription] {.async.} =
  let subscription = RequestFailedSubscription(
    market: market, requestId: none RequestId, callback: callback
  )
  market.subscriptions.onRequestFailed.add(subscription)
  return subscription

method subscribeRequestFailed*(
    market: MockMarket, requestId: RequestId, callback: OnRequestFailed
): Future[Subscription] {.async.} =
  let subscription = RequestFailedSubscription(
    market: market, requestId: some requestId, callback: callback
  )
  market.subscriptions.onRequestFailed.add(subscription)
  return subscription

method subscribeProofSubmission*(
    mock: MockMarket, callback: OnProofSubmitted
): Future[Subscription] {.async.} =
  let subscription = ProofSubmittedSubscription(market: mock, callback: callback)
  mock.subscriptions.onProofSubmitted.add(subscription)
  return subscription

method queryPastStorageRequestedEvents*(
    market: MockMarket, fromBlock: BlockTag
): Future[seq[StorageRequested]] {.async.} =
  return market.requested.map(
    request =>
      StorageRequested(requestId: request.id, ask: request.ask, expiry: request.expiry)
  )

method queryPastStorageRequestedEvents*(
    market: MockMarket, blocksAgo: int
): Future[seq[StorageRequested]] {.async.} =
  return market.requested.map(
    request =>
      StorageRequested(requestId: request.id, ask: request.ask, expiry: request.expiry)
  )

method queryPastSlotFilledEvents*(
    market: MockMarket, fromBlock: BlockTag
): Future[seq[SlotFilled]] {.async.} =
  return market.filled.map(
    slot => SlotFilled(requestId: slot.requestId, slotIndex: slot.slotIndex)
  )

method queryPastSlotFilledEvents*(
    market: MockMarket, blocksAgo: int
): Future[seq[SlotFilled]] {.async.} =
  return market.filled.map(
    slot => SlotFilled(requestId: slot.requestId, slotIndex: slot.slotIndex)
  )

method queryPastSlotFilledEvents*(
    market: MockMarket, fromTime: SecondsSince1970
): Future[seq[SlotFilled]] {.async.} =
  let filtered = market.filled.filter(
    proc(slot: MockSlot): bool =
      if timestamp =? slot.timestamp:
        return timestamp >= fromTime
      else:
        true
  )
  return filtered.map(
    slot => SlotFilled(requestId: slot.requestId, slotIndex: slot.slotIndex)
  )

method unsubscribe*(subscription: RequestSubscription) {.async.} =
  subscription.market.subscriptions.onRequest.keepItIf(it != subscription)

method unsubscribe*(subscription: FulfillmentSubscription) {.async.} =
  subscription.market.subscriptions.onFulfillment.keepItIf(it != subscription)

method unsubscribe*(subscription: SlotFilledSubscription) {.async.} =
  subscription.market.subscriptions.onSlotFilled.keepItIf(it != subscription)

method unsubscribe*(subscription: SlotFreedSubscription) {.async.} =
  subscription.market.subscriptions.onSlotFreed.keepItIf(it != subscription)

method unsubscribe*(subscription: RequestCancelledSubscription) {.async.} =
  subscription.market.subscriptions.onRequestCancelled.keepItIf(it != subscription)

method unsubscribe*(subscription: RequestFailedSubscription) {.async.} =
  subscription.market.subscriptions.onRequestFailed.keepItIf(it != subscription)

method unsubscribe*(subscription: ProofSubmittedSubscription) {.async.} =
  subscription.market.subscriptions.onProofSubmitted.keepItIf(it != subscription)

method unsubscribe*(subscription: SlotReservationsFullSubscription) {.async.} =
  subscription.market.subscriptions.onSlotReservationsFull.keepItIf(it != subscription)
