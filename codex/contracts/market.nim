import std/strutils
import pkg/ethers
import pkg/upraises
import pkg/questionable
import ../utils/exceptions
import ../logutils
import ../market
import ./marketplace
import ./proofs
import ./provider

export market

logScope:
  topics = "marketplace onchain market"

type
  OnChainMarket* = ref object of Market
    contract: Marketplace
    signer: Signer
    rewardRecipient: ?Address
    configuration: ?MarketplaceConfig

  MarketSubscription = market.Subscription
  EventSubscription = ethers.Subscription
  OnChainMarketSubscription = ref object of MarketSubscription
    eventSubscription: EventSubscription

func new*(
    _: type OnChainMarket, contract: Marketplace, rewardRecipient = Address.none
): OnChainMarket =
  without signer =? contract.signer:
    raiseAssert("Marketplace contract should have a signer")

  OnChainMarket(contract: contract, signer: signer, rewardRecipient: rewardRecipient)

proc raiseMarketError(message: string) {.raises: [MarketError].} =
  raise newException(MarketError, message)

template convertEthersError(body) =
  try:
    body
  except EthersError as error:
    raiseMarketError(error.msgDetail)

proc config(market: OnChainMarket): Future[MarketplaceConfig] {.async.} =
  without resolvedConfig =? market.configuration:
    let fetchedConfig = await market.contract.configuration()
    market.configuration = some fetchedConfig
    return fetchedConfig

  return resolvedConfig

proc approveFunds(market: OnChainMarket, amount: UInt256) {.async.} =
  debug "Approving tokens", amount
  convertEthersError:
    let tokenAddress = await market.contract.token()
    let token = Erc20Token.new(tokenAddress, market.signer)
    discard await token.increaseAllowance(market.contract.address(), amount).confirm(1)

method getZkeyHash*(market: OnChainMarket): Future[?string] {.async.} =
  let config = await market.config()
  return some config.proofs.zkeyHash

method getSigner*(market: OnChainMarket): Future[Address] {.async.} =
  convertEthersError:
    return await market.signer.getAddress()

method periodicity*(market: OnChainMarket): Future[Periodicity] {.async.} =
  convertEthersError:
    let config = await market.config()
    let period = config.proofs.period
    return Periodicity(seconds: period)

method proofTimeout*(market: OnChainMarket): Future[UInt256] {.async.} =
  convertEthersError:
    let config = await market.config()
    return config.proofs.timeout

method repairRewardPercentage*(market: OnChainMarket): Future[uint8] {.async.} =
  convertEthersError:
    let config = await market.contract.configuration()
    return config.collateral.repairRewardPercentage

method proofDowntime*(market: OnChainMarket): Future[uint8] {.async.} =
  convertEthersError:
    let config = await market.config()
    return config.proofs.downtime

method getPointer*(market: OnChainMarket, slotId: SlotId): Future[uint8] {.async.} =
  convertEthersError:
    let overrides = CallOverrides(blockTag: some BlockTag.pending)
    return await market.contract.getPointer(slotId, overrides)

method myRequests*(market: OnChainMarket): Future[seq[RequestId]] {.async.} =
  convertEthersError:
    return await market.contract.myRequests

method mySlots*(market: OnChainMarket): Future[seq[SlotId]] {.async.} =
  convertEthersError:
    let slots = await market.contract.mySlots()
    debug "Fetched my slots", numSlots = len(slots)

    return slots

method requestStorage(market: OnChainMarket, request: StorageRequest) {.async.} =
  convertEthersError:
    debug "Requesting storage"
    await market.approveFunds(request.price())
    discard await market.contract.requestStorage(request).confirm(1)

method getRequest*(
    market: OnChainMarket, id: RequestId
): Future[?StorageRequest] {.async.} =
  convertEthersError:
    try:
      return some await market.contract.getRequest(id)
    except ProviderError as e:
      if e.msgDetail.contains("Unknown request"):
        return none StorageRequest
      raise e

method requestState*(
    market: OnChainMarket, requestId: RequestId
): Future[?RequestState] {.async.} =
  convertEthersError:
    try:
      let overrides = CallOverrides(blockTag: some BlockTag.pending)
      return some await market.contract.requestState(requestId, overrides)
    except ProviderError as e:
      if e.msgDetail.contains("Unknown request"):
        return none RequestState
      raise e

method slotState*(market: OnChainMarket, slotId: SlotId): Future[SlotState] {.async.} =
  convertEthersError:
    let overrides = CallOverrides(blockTag: some BlockTag.pending)
    return await market.contract.slotState(slotId, overrides)

method getRequestEnd*(
    market: OnChainMarket, id: RequestId
): Future[SecondsSince1970] {.async.} =
  convertEthersError:
    return await market.contract.requestEnd(id)

method requestExpiresAt*(
    market: OnChainMarket, id: RequestId
): Future[SecondsSince1970] {.async.} =
  convertEthersError:
    return await market.contract.requestExpiry(id)

method getHost(
    market: OnChainMarket, requestId: RequestId, slotIndex: UInt256
): Future[?Address] {.async.} =
  convertEthersError:
    let slotId = slotId(requestId, slotIndex)
    let address = await market.contract.getHost(slotId)
    if address != Address.default:
      return some address
    else:
      return none Address

method getActiveSlot*(market: OnChainMarket, slotId: SlotId): Future[?Slot] {.async.} =
  convertEthersError:
    try:
      return some await market.contract.getActiveSlot(slotId)
    except ProviderError as e:
      if e.msgDetail.contains("Slot is free"):
        return none Slot
      raise e

method fillSlot(
    market: OnChainMarket,
    requestId: RequestId,
    slotIndex: UInt256,
    proof: Groth16Proof,
    collateral: UInt256,
) {.async.} =
  convertEthersError:
    logScope:
      requestId
      slotIndex

    await market.approveFunds(collateral)
    trace "calling fillSlot on contract"
    discard await market.contract.fillSlot(requestId, slotIndex, proof).confirm(1)
    trace "fillSlot transaction completed"

method freeSlot*(market: OnChainMarket, slotId: SlotId) {.async.} =
  convertEthersError:
    var freeSlot: Future[Confirmable]
    if rewardRecipient =? market.rewardRecipient:
      # If --reward-recipient specified, use it as the reward recipient, and use
      # the SP's address as the collateral recipient
      let collateralRecipient = await market.getSigner()
      freeSlot = market.contract.freeSlot(
        slotId,
        rewardRecipient, # --reward-recipient
        collateralRecipient,
      ) # SP's address
    else:
      # Otherwise, use the SP's address as both the reward and collateral
      # recipient (the contract will use msg.sender for both)
      freeSlot = market.contract.freeSlot(slotId)

    discard await freeSlot.confirm(1)

method withdrawFunds(market: OnChainMarket, requestId: RequestId) {.async.} =
  convertEthersError:
    discard await market.contract.withdrawFunds(requestId).confirm(1)

method isProofRequired*(market: OnChainMarket, id: SlotId): Future[bool] {.async.} =
  convertEthersError:
    try:
      let overrides = CallOverrides(blockTag: some BlockTag.pending)
      return await market.contract.isProofRequired(id, overrides)
    except ProviderError as e:
      if e.msgDetail.contains("Slot is free"):
        return false
      raise e

method willProofBeRequired*(market: OnChainMarket, id: SlotId): Future[bool] {.async.} =
  convertEthersError:
    try:
      let overrides = CallOverrides(blockTag: some BlockTag.pending)
      return await market.contract.willProofBeRequired(id, overrides)
    except ProviderError as e:
      if e.msgDetail.contains("Slot is free"):
        return false
      raise e

method getChallenge*(
    market: OnChainMarket, id: SlotId
): Future[ProofChallenge] {.async.} =
  convertEthersError:
    let overrides = CallOverrides(blockTag: some BlockTag.pending)
    return await market.contract.getChallenge(id, overrides)

method submitProof*(market: OnChainMarket, id: SlotId, proof: Groth16Proof) {.async.} =
  convertEthersError:
    discard await market.contract.submitProof(id, proof).confirm(1)

method markProofAsMissing*(
    market: OnChainMarket, id: SlotId, period: Period
) {.async.} =
  convertEthersError:
    discard await market.contract.markProofAsMissing(id, period).confirm(1)

method canProofBeMarkedAsMissing*(
    market: OnChainMarket, id: SlotId, period: Period
): Future[bool] {.async.} =
  let provider = market.contract.provider
  let contractWithoutSigner = market.contract.connect(provider)
  let overrides = CallOverrides(blockTag: some BlockTag.pending)
  try:
    discard await contractWithoutSigner.markProofAsMissing(id, period, overrides)
    return true
  except EthersError as e:
    trace "Proof cannot be marked as missing", msg = e.msg
    return false

method reserveSlot*(
    market: OnChainMarket, requestId: RequestId, slotIndex: UInt256
) {.async.} =
  convertEthersError:
    discard await market.contract
    .reserveSlot(
      requestId,
      slotIndex,
      # reserveSlot runs out of gas for unknown reason, but 100k gas covers it
      TransactionOverrides(gasLimit: some 100000.u256),
    )
    .confirm(1)

method canReserveSlot*(
    market: OnChainMarket, requestId: RequestId, slotIndex: UInt256
): Future[bool] {.async.} =
  convertEthersError:
    return await market.contract.canReserveSlot(requestId, slotIndex)

method subscribeRequests*(
    market: OnChainMarket, callback: OnRequest
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!StorageRequested) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in Request subscription", msg = eventErr.msg
      return

    callback(event.requestId, event.ask, event.expiry)

  convertEthersError:
    let subscription = await market.contract.subscribe(StorageRequested, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotFilled*(
    market: OnChainMarket, callback: OnSlotFilled
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!SlotFilled) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in SlotFilled subscription", msg = eventErr.msg
      return

    callback(event.requestId, event.slotIndex)

  convertEthersError:
    let subscription = await market.contract.subscribe(SlotFilled, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotFilled*(
    market: OnChainMarket,
    requestId: RequestId,
    slotIndex: UInt256,
    callback: OnSlotFilled,
): Future[MarketSubscription] {.async.} =
  proc onSlotFilled(eventRequestId: RequestId, eventSlotIndex: UInt256) =
    if eventRequestId == requestId and eventSlotIndex == slotIndex:
      callback(requestId, slotIndex)

  convertEthersError:
    return await market.subscribeSlotFilled(onSlotFilled)

method subscribeSlotFreed*(
    market: OnChainMarket, callback: OnSlotFreed
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!SlotFreed) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in SlotFreed subscription", msg = eventErr.msg
      return

    callback(event.requestId, event.slotIndex)

  convertEthersError:
    let subscription = await market.contract.subscribe(SlotFreed, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotReservationsFull*(
    market: OnChainMarket, callback: OnSlotReservationsFull
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!SlotReservationsFull) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in SlotReservationsFull subscription",
        msg = eventErr.msg
      return

    callback(event.requestId, event.slotIndex)

  convertEthersError:
    let subscription = await market.contract.subscribe(SlotReservationsFull, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeFulfillment(
    market: OnChainMarket, callback: OnFulfillment
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!RequestFulfilled) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in RequestFulfillment subscription", msg = eventErr.msg
      return

    callback(event.requestId)

  convertEthersError:
    let subscription = await market.contract.subscribe(RequestFulfilled, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeFulfillment(
    market: OnChainMarket, requestId: RequestId, callback: OnFulfillment
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!RequestFulfilled) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in RequestFulfillment subscription", msg = eventErr.msg
      return

    if event.requestId == requestId:
      callback(event.requestId)

  convertEthersError:
    let subscription = await market.contract.subscribe(RequestFulfilled, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestCancelled*(
    market: OnChainMarket, callback: OnRequestCancelled
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!RequestCancelled) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in RequestCancelled subscription", msg = eventErr.msg
      return

    callback(event.requestId)

  convertEthersError:
    let subscription = await market.contract.subscribe(RequestCancelled, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestCancelled*(
    market: OnChainMarket, requestId: RequestId, callback: OnRequestCancelled
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!RequestCancelled) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in RequestCancelled subscription", msg = eventErr.msg
      return

    if event.requestId == requestId:
      callback(event.requestId)

  convertEthersError:
    let subscription = await market.contract.subscribe(RequestCancelled, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestFailed*(
    market: OnChainMarket, callback: OnRequestFailed
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!RequestFailed) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in RequestFailed subscription", msg = eventErr.msg
      return

    callback(event.requestId)

  convertEthersError:
    let subscription = await market.contract.subscribe(RequestFailed, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestFailed*(
    market: OnChainMarket, requestId: RequestId, callback: OnRequestFailed
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!RequestFailed) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in RequestFailed subscription", msg = eventErr.msg
      return

    if event.requestId == requestId:
      callback(event.requestId)

  convertEthersError:
    let subscription = await market.contract.subscribe(RequestFailed, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeProofSubmission*(
    market: OnChainMarket, callback: OnProofSubmitted
): Future[MarketSubscription] {.async.} =
  proc onEvent(eventResult: ?!ProofSubmitted) {.upraises: [].} =
    without event =? eventResult, eventErr:
      error "There was an error in ProofSubmitted subscription", msg = eventErr.msg
      return

    callback(event.id)

  convertEthersError:
    let subscription = await market.contract.subscribe(ProofSubmitted, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method unsubscribe*(subscription: OnChainMarketSubscription) {.async.} =
  await subscription.eventSubscription.unsubscribe()

method queryPastSlotFilledEvents*(
    market: OnChainMarket, fromBlock: BlockTag
): Future[seq[SlotFilled]] {.async.} =
  convertEthersError:
    return await market.contract.queryFilter(SlotFilled, fromBlock, BlockTag.latest)

method queryPastSlotFilledEvents*(
    market: OnChainMarket, blocksAgo: int
): Future[seq[SlotFilled]] {.async.} =
  convertEthersError:
    let fromBlock = await market.contract.provider.pastBlockTag(blocksAgo)

    return await market.queryPastSlotFilledEvents(fromBlock)

method queryPastSlotFilledEvents*(
    market: OnChainMarket, fromTime: SecondsSince1970
): Future[seq[SlotFilled]] {.async.} =
  convertEthersError:
    let fromBlock = await market.contract.provider.blockNumberForEpoch(fromTime)
    return await market.queryPastSlotFilledEvents(BlockTag.init(fromBlock))

method queryPastStorageRequestedEvents*(
    market: OnChainMarket, fromBlock: BlockTag
): Future[seq[StorageRequested]] {.async.} =
  convertEthersError:
    return
      await market.contract.queryFilter(StorageRequested, fromBlock, BlockTag.latest)

method queryPastStorageRequestedEvents*(
    market: OnChainMarket, blocksAgo: int
): Future[seq[StorageRequested]] {.async.} =
  convertEthersError:
    let fromBlock = await market.contract.provider.pastBlockTag(blocksAgo)

    return await market.queryPastStorageRequestedEvents(fromBlock)
