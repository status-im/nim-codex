from std/times import inMilliseconds
import pkg/codex/logutils
import pkg/stew/byteutils
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
import ./marketplacesuite
import ./nodeconfigs

export logutils

logScope:
  topics = "integration test proofs"


marketplacesuite "Hosts submit regular proofs":

  test "hosts submit periodic proofs for slots they fill", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    hardhat:
      HardhatConfig.none,

    clients:
      CodexConfigs.init(nodes=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("node, marketplace")
        .some,

    providers:
      CodexConfigs.init(nodes=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("marketplace", "sales", "reservations", "node", "clock")
        .some,
  ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    let duration = expiry + 5.periods

    let data = await RandomChunker.example(blocks=8)
    createAvailabilities(data.len * 2, duration) # TODO: better value for data.len

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      nodes=3,
      tolerance=1
    )
    check eventually(client0.purchaseStateIs(purchaseId, "started"), timeout = expiry.int * 1000)

    var proofWasSubmitted = false
    proc onProofSubmitted(event: ProofSubmitted) =
      proofWasSubmitted = true

    let subscription = await marketplace.subscribe(ProofSubmitted, onProofSubmitted)

    check eventually(proofWasSubmitted, timeout=(duration - expiry).int * 1000)

    await subscription.unsubscribe()


marketplacesuite "Simulate invalid proofs":

  # TODO: these are very loose tests in that they are not testing EXACTLY how
  # proofs were marked as missed by the validator. These tests should be
  # tightened so that they are showing, as an integration test, that specific
  # proofs are being marked as missed by the validator.

  test "slot is freed after too many invalid proofs submitted", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    hardhat:
      HardhatConfig.none,

    clients:
      CodexConfigs.init(nodes=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("node", "marketplace", "clock")
        .some,

    providers:
      CodexConfigs.init(nodes=1)
        .withSimulateProofFailures(idx=0, failEveryNProofs=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("marketplace", "sales", "reservations", "node", "clock", "slotsbuilder")
        .some,

    validators:
      CodexConfigs.init(nodes=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("validator", "onchain", "ethers", "clock")
        .some
  ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    let duration = expiry + 10.periods

    let data = await RandomChunker.example(blocks=8)
    createAvailabilities(data.len * 2, duration) # TODO: better value for data.len

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      nodes=3,
      tolerance=1,
      proofProbability=1
    )
    let requestId = client0.requestId(purchaseId).get

    check eventually(client0.purchaseStateIs(purchaseId, "started"), timeout = expiry.int * 1000)

    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      if event.requestId == requestId:
        slotWasFreed = true

    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    check eventually(slotWasFreed, timeout=(duration - expiry).int * 1000)

    await subscription.unsubscribe()

  test "slot is not freed when not enough invalid proofs submitted", NodeConfigs(
    # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
    hardhat: HardhatConfig.none,

    clients:
      CodexConfigs.init(nodes=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("marketplace", "sales", "reservations", "node", "clock")
        .some,

    providers:
      CodexConfigs.init(nodes=1)
        .withSimulateProofFailures(idx=0, failEveryNProofs=1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("marketplace", "sales", "reservations", "node")
        .some,

    validators:
      CodexConfigs.init(nodes=1)
        # .debug()
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("validator", "onchain", "ethers", "clock")
        .some
  ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    # In 2 periods you cannot have enough invalid proofs submitted:
    let duration = expiry + 2.periods

    let data = await RandomChunker.example(blocks=8)
    createAvailabilities(data.len * 2, duration) # TODO: better value for data.len

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      expiry=expiry,
      duration=duration,
      nodes=3,
      tolerance=1,
      proofProbability=1
    )
    let requestId = client0.requestId(purchaseId).get

    check eventually(client0.purchaseStateIs(purchaseId, "started"), timeout = expiry.int * 1000)

    var slotWasFreed = false
    proc onSlotFreed(event: SlotFreed) =
      if event.requestId == requestId:
        slotWasFreed = true

    let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

    # check not freed
    await sleepAsync((duration - expiry).int.seconds)
    check not slotWasFreed

    await subscription.unsubscribe()

  # TODO: uncomment once fixed
  # test "host that submits invalid proofs is paid out less", NodeConfigs(
  #   # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
  #   # hardhat: HardhatConfig().withLogFile(),

  #   clients:
  #     CodexConfig()
  #       .nodes(1)
  #       # .debug() # uncomment to enable console log output.debug()
  #       .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
  #       .withLogTopics("node", "erasure", "clock", "purchases"),

  #   providers:
  #     CodexConfig()
  #       .nodes(3)
  #       .simulateProofFailuresFor(providerIdx=0, failEveryNProofs=2)
  #       # .debug() # uncomment to enable console log output
  #       .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
  #       .withLogTopics("marketplace", "sales", "reservations", "node"),

  #   validators:
  #     CodexConfig()
  #       .nodes(1)
  #       # .debug()
  #       .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
  #       .withLogTopics("validator")
  # ):
  #   let client0 = clients()[0].client
  #   let provider0 = providers()[0]
  #   let provider1 = providers()[1]
  #   let provider2 = providers()[2]
  #   let totalPeriods = 25

  #   let datasetSizeInBlocks = 3
  #   let data = await RandomChunker.example(blocks=datasetSizeInBlocks)
  #   # original data = 3 blocks so slot size will be 4 blocks
  #   let slotSize = (DefaultBlockSize * 4.NBytes).Natural.u256

  #   discard provider0.client.postAvailability(
  #     totalSize=slotSize, # should match 1 slot only
  #     duration=totalPeriods.periods.u256,
  #     minPrice=300.u256,
  #     maxCollateral=200.u256
  #   )

  #   let cid = client0.upload(data).get

  #   let purchaseId = await client0.requestStorage(
  #     cid,
  #     duration=totalPeriods.periods,
  #     expiry=10.periods,
  #     nodes=3,
  #     tolerance=1,
  #     origDatasetSizeInBlocks=datasetSizeInBlocks
  #   )

  #   without requestId =? client0.requestId(purchaseId):
  #     fail()

  #   var filledSlotIds: seq[SlotId] = @[]
  #   proc onSlotFilled(event: SlotFilled) =
  #     let slotId = slotId(event.requestId, event.slotIndex)
  #     filledSlotIds.add slotId

  #   let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

  #   # wait til first slot is filled
  #   check eventually filledSlotIds.len > 0

  #   # now add availability for providers 1 and 2, which should allow them to to
  #   # put the remaining slots in their queues
  #   discard provider1.client.postAvailability(
  #     totalSize=slotSize, # should match 1 slot only
  #     duration=totalPeriods.periods.u256,
  #     minPrice=300.u256,
  #     maxCollateral=200.u256
  #   )

  #   check eventually filledSlotIds.len > 1

  #   discard provider2.client.postAvailability(
  #     totalSize=slotSize, # should match 1 slot only
  #     duration=totalPeriods.periods.u256,
  #     minPrice=300.u256,
  #     maxCollateral=200.u256
  #   )

  #   check eventually filledSlotIds.len > 2

  #   # Wait til second slot is filled. SaleFilled happens too quickly, check SaleProving instead.
  #   check eventually provider1.client.saleStateIs(filledSlotIds[1], "SaleProving")
  #   check eventually provider2.client.saleStateIs(filledSlotIds[2], "SaleProving")

  #   check eventually client0.purchaseStateIs(purchaseId, "started")

  #   let currentPeriod = await getCurrentPeriod()
  #   check eventuallyP(
  #     # SaleFinished happens too quickly, check SalePayout instead
  #     provider0.client.saleStateIs(filledSlotIds[0], "SalePayout"),
  #     currentPeriod + totalPeriods.u256 + 1)

  #   check eventuallyP(
  #     # SaleFinished happens too quickly, check SalePayout instead
  #     provider1.client.saleStateIs(filledSlotIds[1], "SalePayout"),
  #     currentPeriod + totalPeriods.u256 + 1)

  #   check eventuallyP(
  #     # SaleFinished happens too quickly, check SalePayout instead
  #     provider2.client.saleStateIs(filledSlotIds[2], "SalePayout"),
  #     currentPeriod + totalPeriods.u256 + 1)

  #   check eventually(
  #     (await token.balanceOf(provider1.ethAccount)) >
  #     (await token.balanceOf(provider0.ethAccount))
  #   )

  #   await subscription.unsubscribe()
