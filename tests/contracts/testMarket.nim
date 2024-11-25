import std/options
import std/importutils
import pkg/chronos
import pkg/ethers/erc20
import codex/contracts
import ../ethertest
import ./examples
import ./time
import ./deployment

privateAccess(OnChainMarket) # enable access to private fields

ethersuite "On-Chain Market":
  let proof = Groth16Proof.example

  var market: OnChainMarket
  var marketplace: Marketplace
  var token: Erc20Token
  var request: StorageRequest
  var slotIndex: UInt256
  var periodicity: Periodicity
  var host: Signer
  var otherHost: Signer
  var hostRewardRecipient: Address

  proc expectedPayout(r: StorageRequest, startTimestamp: UInt256, endTimestamp: UInt256): UInt256 =
    return (endTimestamp - startTimestamp) * r.ask.reward

  proc switchAccount(account: Signer) =
    marketplace = marketplace.connect(account)
    token = token.connect(account)
    market = OnChainMarket.new(marketplace, market.rewardRecipient)

  setup:
    let address = Marketplace.address(dummyVerifier = true)
    marketplace = Marketplace.new(address, ethProvider.getSigner())
    let config = await marketplace.configuration()
    hostRewardRecipient = accounts[2]

    market = OnChainMarket.new(marketplace)
    let tokenAddress = await marketplace.token()
    token = Erc20Token.new(tokenAddress, ethProvider.getSigner())

    periodicity = Periodicity(seconds: config.proofs.period)

    request = StorageRequest.example
    request.client = accounts[0]
    host = ethProvider.getSigner(accounts[1])
    otherHost = ethProvider.getSigner(accounts[3])

    slotIndex = (request.ask.slots div 2).u256

  proc advanceToNextPeriod() {.async.} =
    let currentPeriod = periodicity.periodOf(await ethProvider.currentTime())
    await ethProvider.advanceTimeTo(periodicity.periodEnd(currentPeriod) + 1)

  proc advanceToCancelledRequest(request: StorageRequest) {.async.} =
    let expiry = (await market.requestExpiresAt(request.id)) + 1
    await ethProvider.advanceTimeTo(expiry.u256)

  proc waitUntilProofRequired(slotId: SlotId) {.async.} =
    await advanceToNextPeriod()
    while not (
      (await marketplace.isProofRequired(slotId)) and
      (await marketplace.getPointer(slotId)) < 250
    ):
      await advanceToNextPeriod()

  test "fails to instantiate when contract does not have a signer":
    let storageWithoutSigner = marketplace.connect(ethProvider)
    expect AssertionDefect:
      discard OnChainMarket.new(storageWithoutSigner)

  test "knows signer address":
    check (await market.getSigner()) == (await ethProvider.getSigner().getAddress())

  test "can retrieve proof periodicity":
    let periodicity = await market.periodicity()
    let config = await marketplace.configuration()
    let periodLength = config.proofs.period
    check periodicity.seconds == periodLength

  test "can retrieve proof timeout":
    let proofTimeout = await market.proofTimeout()
    let config = await marketplace.configuration()
    check proofTimeout == config.proofs.timeout

  test "supports marketplace requests":
    await market.requestStorage(request)

  test "can retrieve previously submitted requests":
    check (await market.getRequest(request.id)) == none StorageRequest
    await market.requestStorage(request)
    let r = await market.getRequest(request.id)
    check (r) == some request

  test "withdraws funds to client":
    let clientAddress = request.client

    await market.requestStorage(request)
    await advanceToCancelledRequest(request)
    let startBalanceClient = await token.balanceOf(clientAddress)
    await market.withdrawFunds(request.id)

    let endBalanceClient = await token.balanceOf(clientAddress)

    check endBalanceClient == (startBalanceClient + request.price)

  test "supports request subscriptions":
    var receivedIds: seq[RequestId]
    var receivedAsks: seq[StorageAsk]
    proc onRequest(id: RequestId, ask: StorageAsk, expiry: UInt256) =
      receivedIds.add(id)
      receivedAsks.add(ask)
    let subscription = await market.subscribeRequests(onRequest)
    await market.requestStorage(request)
    check receivedIds == @[request.id]
    check receivedAsks == @[request.ask]
    await subscription.unsubscribe()

  test "supports filling of slots":
    await market.requestStorage(request)
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)

  test "can retrieve host that filled slot":
    await market.requestStorage(request)
    check (await market.getHost(request.id, slotIndex)) == none Address
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    check (await market.getHost(request.id, slotIndex)) == some accounts[0]

  test "supports freeing a slot":
    await market.requestStorage(request)
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    await market.freeSlot(slotId(request.id, slotIndex))
    check (await market.getHost(request.id, slotIndex)) == none Address

  test "supports checking whether proof is required now":
    check (await market.isProofRequired(slotId(request.id, slotIndex))) == false

  test "supports checking whether proof is required soon":
    check (await market.willProofBeRequired(slotId(request.id, slotIndex))) == false

  test "submits proofs":
    await market.requestStorage(request)
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    await advanceToNextPeriod()
    await market.submitProof(slotId(request.id, slotIndex), proof)

  test "marks a proof as missing":
    let slotId = slotId(request, slotIndex)
    await market.requestStorage(request)
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    await waitUntilProofRequired(slotId)
    let missingPeriod = periodicity.periodOf(await ethProvider.currentTime())
    await advanceToNextPeriod()
    await market.markProofAsMissing(slotId, missingPeriod)
    check (await marketplace.missingProofs(slotId)) == 1

  test "can check whether a proof can be marked as missing":
    let slotId = slotId(request, slotIndex)
    await market.requestStorage(request)
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    await waitUntilProofRequired(slotId)
    let missingPeriod = periodicity.periodOf(await ethProvider.currentTime())
    await advanceToNextPeriod()
    check (await market.canProofBeMarkedAsMissing(slotId, missingPeriod)) == true

  test "supports slot filled subscriptions":
    await market.requestStorage(request)
    var receivedIds: seq[RequestId]
    var receivedSlotIndices: seq[UInt256]
    proc onSlotFilled(id: RequestId, slotIndex: UInt256) =
      receivedIds.add(id)
      receivedSlotIndices.add(slotIndex)
    let subscription = await market.subscribeSlotFilled(onSlotFilled)
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    check receivedIds == @[request.id]
    check receivedSlotIndices == @[slotIndex]
    await subscription.unsubscribe()

  test "subscribes only to a certain slot":
    var otherSlot = slotIndex - 1
    await market.requestStorage(request)
    var receivedSlotIndices: seq[UInt256]
    proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
      receivedSlotIndices.add(slotIndex)
    let subscription = await market.subscribeSlotFilled(request.id, slotIndex, onSlotFilled)
    await market.reserveSlot(request.id, otherSlot)
    await market.fillSlot(request.id, otherSlot, proof, request.ask.collateral)
    check receivedSlotIndices.len == 0
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    check receivedSlotIndices == @[slotIndex]
    await subscription.unsubscribe()

  test "supports slot freed subscriptions":
    await market.requestStorage(request)
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    var receivedRequestIds: seq[RequestId] = @[]
    var receivedIdxs: seq[UInt256] = @[]
    proc onSlotFreed(requestId: RequestId, idx: UInt256) =
      receivedRequestIds.add(requestId)
      receivedIdxs.add(idx)
    let subscription = await market.subscribeSlotFreed(onSlotFreed)
    await market.freeSlot(slotId(request.id, slotIndex))
    check receivedRequestIds == @[request.id]
    check receivedIdxs == @[slotIndex]
    await subscription.unsubscribe()

  test "supports slot reservations full subscriptions":
    let account2 = ethProvider.getSigner(accounts[2])
    let account3 = ethProvider.getSigner(accounts[3])

    await market.requestStorage(request)

    var receivedRequestIds: seq[RequestId] = @[]
    var receivedIdxs: seq[UInt256] = @[]
    proc onSlotReservationsFull(requestId: RequestId, idx: UInt256) =
      receivedRequestIds.add(requestId)
      receivedIdxs.add(idx)
    let subscription =
      await market.subscribeSlotReservationsFull(onSlotReservationsFull)

    await market.reserveSlot(request.id, slotIndex)
    switchAccount(account2)
    await market.reserveSlot(request.id, slotIndex)
    switchAccount(account3)
    await market.reserveSlot(request.id, slotIndex)

    check receivedRequestIds == @[request.id]
    check receivedIdxs == @[slotIndex]
    await subscription.unsubscribe()

  test "support fulfillment subscriptions":
    await market.requestStorage(request)
    var receivedIds: seq[RequestId]
    proc onFulfillment(id: RequestId) =
      receivedIds.add(id)
    let subscription = await market.subscribeFulfillment(request.id, onFulfillment)
    for slotIndex in 0..<request.ask.slots:
      await market.reserveSlot(request.id, slotIndex.u256)
      await market.fillSlot(request.id, slotIndex.u256, proof, request.ask.collateral)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "subscribes only to fulfillment of a certain request":
    var otherRequest = StorageRequest.example
    otherRequest.client = accounts[0]

    await market.requestStorage(request)
    await market.requestStorage(otherRequest)

    var receivedIds: seq[RequestId]
    proc onFulfillment(id: RequestId) =
      receivedIds.add(id)

    let subscription = await market.subscribeFulfillment(request.id, onFulfillment)

    for slotIndex in 0..<request.ask.slots:
      await market.reserveSlot(request.id, slotIndex.u256)
      await market.fillSlot(request.id, slotIndex.u256, proof, request.ask.collateral)
    for slotIndex in 0..<otherRequest.ask.slots:
      await market.reserveSlot(otherRequest.id, slotIndex.u256)
      await market.fillSlot(otherRequest.id, slotIndex.u256, proof, otherRequest.ask.collateral)

    check receivedIds == @[request.id]

    await subscription.unsubscribe()

  test "support request cancelled subscriptions":
    await market.requestStorage(request)

    var receivedIds: seq[RequestId]
    proc onRequestCancelled(id: RequestId) =
      receivedIds.add(id)
    let subscription = await market.subscribeRequestCancelled(request.id, onRequestCancelled)

    await advanceToCancelledRequest(request)
    await market.withdrawFunds(request.id)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "support request failed subscriptions":
    await market.requestStorage(request)

    var receivedIds: seq[RequestId]
    proc onRequestFailed(id: RequestId) =
      receivedIds.add(id)
    let subscription = await market.subscribeRequestFailed(request.id, onRequestFailed)

    for slotIndex in 0..<request.ask.slots:
      await market.reserveSlot(request.id, slotIndex.u256)
      await market.fillSlot(request.id, slotIndex.u256, proof, request.ask.collateral)
    for slotIndex in 0..request.ask.maxSlotLoss:
      let slotId = request.slotId(slotIndex.u256)
      while true:
        let slotState = await marketplace.slotState(slotId)
        if slotState == SlotState.Free:
          break
        await waitUntilProofRequired(slotId)
        let missingPeriod = periodicity.periodOf(await ethProvider.currentTime())
        await advanceToNextPeriod()
        discard await marketplace.markProofAsMissing(slotId, missingPeriod)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "subscribes only to a certain request cancellation":
    var otherRequest = request
    otherRequest.nonce = Nonce.example
    await market.requestStorage(request)
    await market.requestStorage(otherRequest)

    var receivedIds: seq[RequestId]
    proc onRequestCancelled(requestId: RequestId) =
      receivedIds.add(requestId)

    let subscription = await market.subscribeRequestCancelled(request.id, onRequestCancelled)
    await advanceToCancelledRequest(otherRequest) # shares expiry with otherRequest
    await market.withdrawFunds(otherRequest.id)
    check receivedIds.len == 0
    await market.withdrawFunds(request.id)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "supports proof submission subscriptions":
    await market.requestStorage(request)
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    await advanceToNextPeriod()
    var receivedIds: seq[SlotId]
    proc onProofSubmission(id: SlotId) =
      receivedIds.add(id)
    let subscription = await market.subscribeProofSubmission(onProofSubmission)
    await market.submitProof(slotId(request.id, slotIndex), proof)
    check receivedIds == @[slotId(request.id, slotIndex)]
    await subscription.unsubscribe()

  test "request is none when unknown":
    check isNone await market.getRequest(request.id)

  test "can retrieve active requests":
    await market.requestStorage(request)
    var request2 = StorageRequest.example
    request2.client = accounts[0]
    await market.requestStorage(request2)
    check (await market.myRequests()) == @[request.id, request2.id]

  test "retrieves correct request state when request is unknown":
    check (await market.requestState(request.id)) == none RequestState

  test "can retrieve request state":
    await market.requestStorage(request)
    for slotIndex in 0..<request.ask.slots:
      await market.reserveSlot(request.id, slotIndex.u256)
      await market.fillSlot(request.id, slotIndex.u256, proof, request.ask.collateral)
    check (await market.requestState(request.id)) == some RequestState.Started

  test "can retrieve active slots":
    await market.requestStorage(request)
    await market.reserveSlot(request.id, slotIndex - 1)
    await market.fillSlot(request.id, slotIndex - 1, proof, request.ask.collateral)
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    let slotId1 = request.slotId(slotIndex - 1)
    let slotId2 = request.slotId(slotIndex)
    check (await market.mySlots()) == @[slotId1, slotId2]

  test "returns none when slot is empty":
    await market.requestStorage(request)
    let slotId = request.slotId(slotIndex)
    check (await market.getActiveSlot(slotId)) == none Slot

  test "can retrieve request details from slot id":
    await market.requestStorage(request)
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    let slotId = request.slotId(slotIndex)
    let expected = Slot(request: request, slotIndex: slotIndex)
    check (await market.getActiveSlot(slotId)) == some expected

  test "retrieves correct slot state when request is unknown":
    let slotId = request.slotId(slotIndex)
    check (await market.slotState(slotId)) == SlotState.Free

  test "retrieves correct slot state once filled":
    await market.requestStorage(request)
    await market.reserveSlot(request.id, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    let slotId = request.slotId(slotIndex)
    check (await market.slotState(slotId)) == SlotState.Filled

  test "can query past StorageRequested events":
    var request1 = StorageRequest.example
    var request2 = StorageRequest.example
    request1.client = accounts[0]
    request2.client = accounts[0]
    await market.requestStorage(request)
    await market.requestStorage(request1)
    await market.requestStorage(request2)

    # `market.requestStorage` executes an `approve` tx before the
    # `requestStorage` tx, so that's two PoA blocks per `requestStorage` call (6
    # blocks for 3 calls). We don't need to check the `approve` for the first
    # `requestStorage` call, so we only need to check 5 "blocks ago". "blocks
    # ago".

    proc getsPastRequest(): Future[bool] {.async.} =
      let reqs = await market.queryPastEvents(StorageRequested, 5)
      reqs.mapIt(it.requestId) == @[request.id, request1.id, request2.id]

    check eventually await getsPastRequest()

  test "can query past SlotFilled events":
    await market.requestStorage(request)
    await market.reserveSlot(request.id, 0.u256)
    await market.reserveSlot(request.id, 1.u256)
    await market.reserveSlot(request.id, 2.u256)
    await market.fillSlot(request.id, 0.u256, proof, request.ask.collateral)
    await market.fillSlot(request.id, 1.u256, proof, request.ask.collateral)
    await market.fillSlot(request.id, 2.u256, proof, request.ask.collateral)
    let slotId = request.slotId(slotIndex)

    # `market.fill` executes an `approve` tx before the `fillSlot` tx, so that's
    # two PoA blocks per `fillSlot` call (6 blocks for 3 calls). We don't need
    # to check the `approve` for the first `fillSlot` call, so we only need to
    # check 5 "blocks ago".
    let events = await market.queryPastEvents(SlotFilled, 5)
    check events == @[
      SlotFilled(requestId: request.id, slotIndex: 0.u256),
      SlotFilled(requestId: request.id, slotIndex: 1.u256),
      SlotFilled(requestId: request.id, slotIndex: 2.u256),
    ]

  test "past event query can specify negative `blocksAgo` parameter":
    await market.requestStorage(request)

    check eventually (
      (await market.queryPastEvents(StorageRequested, blocksAgo = -2)) ==
      (await market.queryPastEvents(StorageRequested, blocksAgo = 2))
    )

  test "pays rewards and collateral to host":
    await market.requestStorage(request)

    let address = await host.getAddress()
    switchAccount(host)
    await market.reserveSlot(request.id, 0.u256)
    await market.fillSlot(request.id, 0.u256, proof, request.ask.collateral)
    let filledAt = (await ethProvider.currentTime()) - 1.u256

    for slotIndex in 1..<request.ask.slots:
      await market.reserveSlot(request.id, slotIndex.u256)
      await market.fillSlot(request.id, slotIndex.u256, proof, request.ask.collateral)

    let requestEnd = await market.getRequestEnd(request.id)
    await ethProvider.advanceTimeTo(requestEnd.u256 + 1)

    let startBalance = await token.balanceOf(address)
    await market.freeSlot(request.slotId(0.u256))
    let endBalance = await token.balanceOf(address)

    let expectedPayout = request.expectedPayout(filledAt, requestEnd.u256)
    check endBalance == (startBalance + expectedPayout + request.ask.collateral)

  test "pays rewards to reward recipient, collateral to host":
    market = OnChainMarket.new(marketplace, hostRewardRecipient.some)
    let hostAddress = await host.getAddress()

    await market.requestStorage(request)

    switchAccount(host)
    await market.reserveSlot(request.id, 0.u256)
    await market.fillSlot(request.id, 0.u256, proof, request.ask.collateral)
    let filledAt = (await ethProvider.currentTime()) - 1.u256

    for slotIndex in 1..<request.ask.slots:
      await market.reserveSlot(request.id, slotIndex.u256)
      await market.fillSlot(request.id, slotIndex.u256, proof, request.ask.collateral)

    let requestEnd = await market.getRequestEnd(request.id)
    await ethProvider.advanceTimeTo(requestEnd.u256 + 1)

    let startBalanceHost = await token.balanceOf(hostAddress)
    let startBalanceReward = await token.balanceOf(hostRewardRecipient)

    await market.freeSlot(request.slotId(0.u256))

    let endBalanceHost = await token.balanceOf(hostAddress)
    let endBalanceReward = await token.balanceOf(hostRewardRecipient)

    let expectedPayout = request.expectedPayout(filledAt, requestEnd.u256)
    check endBalanceHost == (startBalanceHost + request.ask.collateral)
    check endBalanceReward == (startBalanceReward + expectedPayout)
