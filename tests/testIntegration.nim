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
  # IntegrationTestConfig(testFile: "./integration/testcli", startHardhat: true),
  # IntegrationTestConfig(testFile: "./integration/testrestapi", startHardhat: true),
  # IntegrationTestConfig(testFile: "./integration/testupdownload", startHardhat: true),
  # IntegrationTestConfig(testFile: "./integration/testsales", startHardhat: true),
  # IntegrationTestConfig(testFile: "./integration/testpurchasing", startHardhat: true),
  # IntegrationTestConfig(testFile: "./integration/testblockexpiration", startHardhat: true),
  IntegrationTestConfig(
    name: "Basic Marketplace and payout tests",
    testFile: "./integration/testmarketplace",
    startHardhat: true),
  # IntegrationTestConfig(testFile: "./integration/testproofs", startHardhat: true),
  # IntegrationTestConfig(testFile: "./integration/testvalidator", startHardhat: true),
  IntegrationTestConfig(
    name: "Erasure Coding Bug",
    testFile: "./integration/testecbug",
    startHardhat: true)
]

proc run() {.async.} =
  let manager = TestManager.new(
    configs = TestConfigs,
    debugTestHarness = true,
    debugHardhat = false)
  try:
    trace "starting test manager"
    await manager.start()
  finally:
    trace "stopping test manager"
    await manager.stop()

waitFor run()
