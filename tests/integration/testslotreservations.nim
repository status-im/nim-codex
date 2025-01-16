import pkg/stew/byteutils
import pkg/codex/units
import ../examples
import ../contracts/time
import ../contracts/deployment
import ./marketplacesuite
import ./nodeconfigs
import ./hardhatconfig

marketplacesuite "Slot reservations":

  test "nonce does not go too high when reserving slots",
    NodeConfigs(
      # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
      hardhat: HardhatConfig.none,

      clients:
        CodexConfigs.init(nodes=1)
          # .debug() # uncomment to enable console log output.debug()
          .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
          .withLogTopics("node", "erasure", "marketplace")
          .some,

      providers:
        CodexConfigs.init(nodes=6)
          # .debug() # uncomment to enable console log output
          .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
          .withLogTopics("node", "marketplace", "sales", "reservations", "proving", "ethers", "statemachine")
          .some,
  ):
    let reward = 400.u256
    let duration = 50.periods
    let collateral = 200.u256
    let expiry = 30.periods
    let data = await RandomChunker.example(blocks=8)
    let client = clients()[0]
    let clientApi = client.client

    # provider makes storage available
    for i in 0..<providers().len:
      let provider = providers()[i].client
      discard provider.postAvailability(
        # make availability size small enough that we can only fill one slot
        totalSize=(data.len div 2).u256,
        duration=duration.u256,
        minPrice=reward,
        maxCollateral=collateral)

    let cid = clientApi.upload(data).get

    var slotIdxFilled: seq[UInt256] = @[]
    proc onSlotFilled(event: SlotFilled) =
      slotIdxFilled.add event.slotIndex

    let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    # client requests storage but requires multiple slots to host the content
    let id = await clientApi.requestStorage(
      cid,
      duration=duration,
      reward=reward,
      expiry=expiry,
      collateral=collateral,
      nodes=5,
      tolerance=1
    )

    # wait until all slots filled
    check eventually(slotIdxFilled.len == 5, timeout=expiry.int * 1000)

    teardown:
      check logsDoNotContain(Role.Provider, "Nonce too high")

    await subscription.unsubscribe()
