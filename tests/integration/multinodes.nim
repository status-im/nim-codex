import std/os
import std/sequtils
import std/strutils
import std/sugar
import std/times
import pkg/codex/conf
import pkg/codex/logutils
import pkg/chronos/transports/stream
import pkg/ethers
import pkg/questionable
import ./codexconfig
import ./codexprocess
import ./hardhatconfig
import ./hardhatprocess
import ./nodeconfigs
import ../asynctest
import ../checktest

export asynctest
export ethers except `%`
export hardhatprocess
export codexprocess
export hardhatconfig
export codexconfig

type
  RunningNode* = ref object
    role*: Role
    node*: NodeProcess
  Role* {.pure.} = enum
    Client,
    Provider,
    Validator,
    Hardhat
  MultiNodeSuiteError = object of CatchableError

proc raiseMultiNodeSuiteError(msg: string) =
  raise newException(MultiNodeSuiteError, msg)

proc nextFreePort(startPort: int): Future[int] {.async.} =

  proc client(server: StreamServer, transp: StreamTransport) {.async.} =
    await transp.closeWait()

  var port = startPort
  while true:
    trace "checking if port is free", port
    try:
      let host = initTAddress("127.0.0.1", port)
      # We use ReuseAddr here only to be able to reuse the same IP/Port when
      # there's a TIME_WAIT socket. It's useful when running the test multiple
      # times or if a test ran previously using the same port.
      var server = createStreamServer(host, client, {ReuseAddr})
      trace "port is free", port
      await server.closeWait()
      return port
    except TransportOsError:
      trace "port is not free", port
      inc port

template multinodesuite*(name: string, body: untyped) =

  asyncchecksuite name:

    var running: seq[RunningNode]
    var bootstrap: string
    let starttime = now().format("yyyy-MM-dd'_'HH:mm:ss")
    var currentTestName = ""
    var nodeConfigs: NodeConfigs
    var ethProvider {.inject, used.}: JsonRpcProvider
    var accounts {.inject, used.}: seq[Address]
    var snapshot: JsonNode

    template test(tname, startNodeConfigs, tbody) =
      currentTestName = tname
      nodeConfigs = startNodeConfigs
      test tname:
        tbody

    proc sanitize(pathSegment: string): string =
      var sanitized = pathSegment
      for invalid in invalidFilenameChars.items:
        sanitized = sanitized.replace(invalid, '_')
                             .replace(' ', '_')
      sanitized

    proc getLogFile(role: Role, index: ?int): string =
      # create log file path, format:
      # tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log

      var logDir = currentSourcePath.parentDir() /
        "logs" /
        sanitize($starttime & "__" & name) /
        sanitize($currentTestName)
      createDir(logDir)

      var fn = $role
      if idx =? index:
        fn &= "_" & $idx
      fn &= ".log"

      let fileName = logDir / fn
      return fileName

    proc newHardhatProcess(
      config: HardhatConfig,
      role: Role
    ): Future[NodeProcess] {.async.} =

      var args: seq[string] = @[]
      if config.logFile:
        let updatedLogFile = getLogFile(role, none int)
        args.add "--log-file=" & updatedLogFile

      let node = await HardhatProcess.startNode(args, config.debugEnabled, "hardhat")
      try:
        await node.waitUntilStarted()
      except NodeProcessError as e:
        raiseMultiNodeSuiteError "hardhat node not started: " & e.msg

      trace "hardhat node started"
      return node

    proc newCodexProcess(roleIdx: int,
                        conf: CodexConfig,
                        role: Role
    ): Future[NodeProcess] {.async.} =

      let nodeIdx = running.len
      var config = conf

      if nodeIdx > accounts.len - 1:
        raiseMultiNodeSuiteError "Cannot start node at nodeIdx " & $nodeIdx &
          ", not enough eth accounts."

      let datadir = getTempDir() / "Codex" /
        sanitize($starttime) /
        sanitize($role & "_" & $roleIdx)

      try:
        if config.logFile.isSome:
          let updatedLogFile = getLogFile(role, some roleIdx)
          config.withLogFile(updatedLogFile)

        config.addCliOption("--api-port", $ await nextFreePort(8080 + nodeIdx))
        config.addCliOption("--data-dir", datadir)
        config.addCliOption("--nat", "127.0.0.1")
        config.addCliOption("--listen-addrs", "/ip4/127.0.0.1/tcp/0")
        config.addCliOption("--disc-ip", "127.0.0.1")
        config.addCliOption("--disc-port", $ await nextFreePort(8090 + nodeIdx))

      except CodexConfigError as e:
        raiseMultiNodeSuiteError "invalid cli option, error: " & e.msg

      let node = await CodexProcess.startNode(
        config.cliArgs,
        config.debugEnabled,
        $role & $roleIdx
      )

      try:
        await node.waitUntilStarted()
        trace "node started", nodeName = $role & $roleIdx
      except NodeProcessError as e:
        raiseMultiNodeSuiteError "node not started, error: " & e.msg

      return node

    proc hardhat: HardhatProcess =
      for r in running:
        if r.role == Role.Hardhat:
          return HardhatProcess(r.node)
      return nil

    proc clients: seq[CodexProcess] {.used.} =
      return collect:
        for r in running:
          if r.role == Role.Client:
            CodexProcess(r.node)

    proc providers: seq[CodexProcess] {.used.} =
      return collect:
        for r in running:
          if r.role == Role.Provider:
            CodexProcess(r.node)

    proc validators: seq[CodexProcess] {.used.} =
      return collect:
        for r in running:
          if r.role == Role.Validator:
            CodexProcess(r.node)

    proc startHardhatNode(config: HardhatConfig): Future[NodeProcess] {.async.} =
      return await newHardhatProcess(config, Role.Hardhat)

    proc startClientNode(conf: CodexConfig): Future[NodeProcess] {.async.} =
      let clientIdx = clients().len
      var config = conf
      config.addCliOption(StartUpCmd.persistence, "--eth-account", $accounts[running.len])
      return await newCodexProcess(clientIdx, config, Role.Client)

    proc startProviderNode(conf: CodexConfig): Future[NodeProcess] {.async.} =
      let providerIdx = providers().len
      var config = conf
      config.addCliOption("--bootstrap-node", bootstrap)
      config.addCliOption(StartUpCmd.persistence, "--eth-account", $accounts[running.len])
      config.addCliOption(PersistenceCmd.prover, "--circom-r1cs",
        "vendor/codex-contracts-eth/verifier/networks/hardhat/proof_main.r1cs")
      config.addCliOption(PersistenceCmd.prover, "--circom-wasm",
        "vendor/codex-contracts-eth/verifier/networks/hardhat/proof_main.wasm")
      config.addCliOption(PersistenceCmd.prover, "--circom-zkey",
        "vendor/codex-contracts-eth/verifier/networks/hardhat/proof_main.zkey")

      return await newCodexProcess(providerIdx, config, Role.Provider)

    proc startValidatorNode(conf: CodexConfig): Future[NodeProcess] {.async.} =
      let validatorIdx = validators().len
      var config = conf
      config.addCliOption("--bootstrap-node", bootstrap)
      config.addCliOption(StartUpCmd.persistence, "--eth-account", $accounts[running.len])
      config.addCliOption(StartUpCmd.persistence, "--validator")

      return await newCodexProcess(validatorIdx, config, Role.Validator)

    proc teardownImpl() {.async.} =
      for nodes in @[validators(), clients(), providers()]:
        for node in nodes:
          await node.stop() # also stops rest client
          node.removeDataDir()

      # if hardhat was started in the test, kill the node
      # otherwise revert the snapshot taken in the test setup
      let hardhat = hardhat()
      if not hardhat.isNil:
        await hardhat.stop()
      else:
        discard await send(ethProvider, "evm_revert", @[snapshot])

      running = @[]

    template failAndTeardownOnError(message: string, tryBody: untyped) =
      try:
        tryBody
      except CatchableError as er:
        fatal message, error=er.msg
        echo "[FATAL] ", message, ": ", er.msg
        await teardownImpl()
        when declared(teardownAllIMPL):
          teardownAllIMPL()
        fail()
        quit(1)

    setup:
      if var conf =? nodeConfigs.hardhat:
        try:
          let node = await startHardhatNode(conf)
          running.add RunningNode(role: Role.Hardhat, node: node)
        except CatchableError as e:
          echo "failed to start hardhat node"
          fail()
          quit(1)

      try:
        # Workaround for https://github.com/NomicFoundation/hardhat/issues/2053
        # Do not use websockets, but use http and polling to stop subscriptions
        # from being removed after 5 minutes
        ethProvider = JsonRpcProvider.new("http://localhost:8545")
        # if hardhat was NOT started by the test, take a snapshot so it can be
        # reverted in the test teardown
        if nodeConfigs.hardhat.isNone:
          snapshot = await send(ethProvider, "evm_snapshot")
        accounts = await ethProvider.listAccounts()
      except CatchableError as e:
        echo "Hardhat not running. Run hardhat manually " &
            "before executing tests, or include a " &
            "HardhatConfig in the test setup."
        fail()
        quit(1)

      if var clients =? nodeConfigs.clients:
        failAndTeardownOnError "failed to start client nodes":
          for config in clients.configs:
            let node = await startClientNode(config)
            running.add RunningNode(
                          role: Role.Client,
                          node: node
                        )
            if clients().len == 1:
              without ninfo =? CodexProcess(node).client.info():
                # raise CatchableError instead of Defect (with .get or !) so we
                # can gracefully shutdown and prevent zombies
                raiseMultiNodeSuiteError "Failed to get node info"
              bootstrap = ninfo["spr"].getStr()

      if var providers =? nodeConfigs.providers:
        failAndTeardownOnError "failed to start provider nodes":
          for config in providers.configs.mitems:
            let node = await startProviderNode(config)
            running.add RunningNode(
                          role: Role.Provider,
                          node: node
                        )

      if var validators =? nodeConfigs.validators:
        failAndTeardownOnError "failed to start validator nodes":
          for config in validators.configs.mitems:
            let node = await startValidatorNode(config)
            running.add RunningNode(
                          role: Role.Validator,
                          node: node
                        )

      # ensure that we have a recent block with a fresh timestamp
      discard await send(ethProvider, "evm_mine")

    teardown:
      await teardownImpl()

    body
