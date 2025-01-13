# import ./integration/testcli
# import ./integration/testrestapi
# import ./integration/testupdownload
# import ./integration/testsales
# import ./integration/testpurchasing
# import ./integration/testblockexpiration
# import ./integration/testmarketplace
# import ./integration/testproofs
# import ./integration/testvalidator
# import ./integration/testecbug

import pkg/chronos
import pkg/codex/logutils
import ./integration/testmanager

{.warning[UnusedImport]:off.}

const TestConfigs = @[
  IntegrationTestConfig.init("./integration/testcli", startHardhat = true),
  IntegrationTestConfig.init("./integration/testrestapi", startHardhat = false),
  # IntegrationTestConfig.init("./integration/testupdownload", startHardhat = true),
  # IntegrationTestConfig.init("./integration/testsales", startHardhat = true),
  # IntegrationTestConfig.init("./integration/testpurchasing", startHardhat = true),
  # IntegrationTestConfig.init("./integration/testblockexpiration", startHardhat = true),
  # IntegrationTestConfig.init(
  #   name = "Basic Marketplace and payout tests",
  #   testFile = "./integration/testmarketplace",
  #   startHardhat = true),
  # IntegrationTestConfig("./integration/testproofs", startHardhat = true),
  # IntegrationTestConfig("./integration/testvalidator", startHardhat = true),
  IntegrationTestConfig.init(
    name = "Erasure Coding Bug",
    testFile = "./integration/testecbug",
    startHardhat = true)
]

proc run() {.async.} =
  let manager = TestManager.new(
    configs = TestConfigs,
    debugTestHarness = true, # Echos stderr if there's a test failure or error (error in running the test)
    debugCodexNodes = true, # Echos stdout from the Codex process (chronicles logs). If test uses a multinodesuite, requires CodexConfig.debug to be enabled
    debugHardhat = false)
  try:
    trace "starting test manager"
    await manager.start()
  finally:
    trace "stopping test manager"
    await manager.stop()

waitFor run()
