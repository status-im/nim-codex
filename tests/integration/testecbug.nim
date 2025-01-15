from pkg/libp2p import Cid, init
import ../examples
import ./marketplacesuite
import ./nodeconfigs
import ./hardhatconfig

marketplacesuite "Bug #821 - node crashes during erasure coding":
  test "should be able to create storage request and download dataset",
    NodeConfigs(
      clients: CodexConfigs
        .init(nodes = 1)
        # .debug() # uncomment to enable console log output.debug()
        .withLogFile()
        # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("node", "erasure", "marketplace").some,
      providers: CodexConfigs.init(nodes = 0)
      # .debug() # uncomment to enable console log output
      # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      # .withLogTopics("node", "marketplace", "sales", "reservations", "node", "proving", "clock")
      .some,
    ):
    let reward = 400.u256
    let duration = 20.periods
    let collateral = 200.u256
    let expiry = 10.periods
    let data = await RandomChunker.example(blocks = 8)
    let client = clients()[0]
    let clientApi = client.client

    let cid = clientApi.upload(data).get

    var requestId = none RequestId
    proc onStorageRequested(eventResult: ?!StorageRequested) =
      assert not eventResult.isErr
      requestId = some (!eventResult).requestId

    let subscription = await marketplace.subscribe(StorageRequested, onStorageRequested)

    # client requests storage but requires multiple slots to host the content
    let id = await clientApi.requestStorage(
      cid,
      duration = duration,
      reward = reward,
      expiry = expiry,
      collateral = collateral,
      nodes = 3,
      tolerance = 1,
    )

    check eventually(requestId.isSome, timeout = expiry.int * 1000)

    let request = await marketplace.getRequest(requestId.get)
    let cidFromRequest = Cid.init(request.content.cid).get()
    let downloaded = await clientApi.downloadBytes(cidFromRequest, local = true)
    check downloaded.isOk
    check downloaded.get.toHex == data.toHex

    await subscription.unsubscribe()
