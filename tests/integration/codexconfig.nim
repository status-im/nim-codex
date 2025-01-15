import std/options
import std/os
import std/sequtils
import std/strutils
import std/sugar
import std/tables
from pkg/chronicles import LogLevel
import pkg/codex/conf
import pkg/codex/units
import pkg/confutils
import pkg/confutils/defs
import libp2p except setup
import pkg/questionable
import ./clioption

export clioption
export confutils

type
  CodexConfigs* = object
    configs*: seq[CodexConfig]

  CodexConfig* = object
    cliOptions: Table[StartUpCmd, Table[string, CliOption]]
    cliPersistenceOptions: Table[PersistenceCmd, Table[string, CliOption]]
    debugEnabled*: bool

  CodexConfigError* = object of CatchableError

proc cliArgs*(config: CodexConfig): seq[string] {.gcsafe, raises: [CodexConfigError].}

proc raiseCodexConfigError(msg: string) {.raises: [CodexConfigError].} =
  raise newException(CodexConfigError, msg)

template convertError(body) =
  try:
    body
  except CatchableError as e:
    raiseCodexConfigError e.msg

proc init*(_: type CodexConfigs, nodes = 1): CodexConfigs {.raises: [].} =
  CodexConfigs(configs: newSeq[CodexConfig](nodes))

func nodes*(self: CodexConfigs): int =
  self.configs.len

proc checkBounds(self: CodexConfigs, idx: int) {.raises: [CodexConfigError].} =
  if idx notin 0 ..< self.configs.len:
    raiseCodexConfigError "index must be in bounds of the number of nodes"

proc buildConfig(
    config: CodexConfig, msg: string
): CodexConf {.raises: [CodexConfigError].} =
  proc postFix(msg: string): string =
    if msg.len > 0:
      ": " & msg
    else:
      ""

  try:
    return CodexConf.load(cmdLine = config.cliArgs, quitOnFailure = false)
  except ConfigurationError as e:
    raiseCodexConfigError msg & e.msg.postFix
  except Exception as e:
    ## TODO: remove once proper exception handling added to nim-confutils
    raiseCodexConfigError msg & e.msg.postFix

proc addCliOption*(
    config: var CodexConfig, group = PersistenceCmd.noCmd, cliOption: CliOption
) {.raises: [CodexConfigError].} =
  var options = config.cliPersistenceOptions.getOrDefault(group)
  options[cliOption.key] = cliOption # overwrite if already exists
  config.cliPersistenceOptions[group] = options
  discard config.buildConfig("Invalid cli arg " & $cliOption)

proc addCliOption*(
    config: var CodexConfig, group = PersistenceCmd.noCmd, key: string, value = ""
) {.raises: [CodexConfigError].} =
  config.addCliOption(group, CliOption(key: key, value: value))

proc addCliOption*(
    config: var CodexConfig, group = StartUpCmd.noCmd, cliOption: CliOption
) {.raises: [CodexConfigError].} =
  var options = config.cliOptions.getOrDefault(group)
  options[cliOption.key] = cliOption # overwrite if already exists
  config.cliOptions[group] = options
  discard config.buildConfig("Invalid cli arg " & $cliOption)

proc addCliOption*(
    config: var CodexConfig, group = StartUpCmd.noCmd, key: string, value = ""
) {.raises: [CodexConfigError].} =
  config.addCliOption(group, CliOption(key: key, value: value))

proc addCliOption*(
    config: var CodexConfig, cliOption: CliOption
) {.raises: [CodexConfigError].} =
  config.addCliOption(StartUpCmd.noCmd, cliOption)

proc addCliOption*(
    config: var CodexConfig, key: string, value = ""
) {.raises: [CodexConfigError].} =
  config.addCliOption(StartUpCmd.noCmd, CliOption(key: key, value: value))

proc cliArgs*(config: CodexConfig): seq[string] {.gcsafe, raises: [CodexConfigError].} =
  ## converts CodexConfig cli options and command groups in a sequence of args
  ## and filters out cli options by node index if provided in the CliOption
  var args: seq[string] = @[]

  convertError:
    for cmd in StartUpCmd:
      if config.cliOptions.hasKey(cmd):
        if cmd != StartUpCmd.noCmd:
          args.add $cmd
        var opts = config.cliOptions[cmd].values.toSeq
        args = args.concat(opts.map(o => $o))

    for cmd in PersistenceCmd:
      if config.cliPersistenceOptions.hasKey(cmd):
        if cmd != PersistenceCmd.noCmd:
          args.add $cmd
        var opts = config.cliPersistenceOptions[cmd].values.toSeq
        args = args.concat(opts.map(o => $o))

    return args

proc logFile*(config: CodexConfig): ?string {.raises: [CodexConfigError].} =
  let built = config.buildConfig("Invalid codex config cli params")
  built.logFile

proc logLevel*(config: CodexConfig): LogLevel {.raises: [CodexConfigError].} =
  convertError:
    let built = config.buildConfig("Invalid codex config cli params")
    return parseEnum[LogLevel](built.logLevel.toUpperAscii)

proc debug*(
    self: CodexConfigs, idx: int, enabled = true
): CodexConfigs {.raises: [CodexConfigError].} =
  ## output log in stdout for a specific node in the group

  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].debugEnabled = enabled
  return startConfig

proc debug*(self: CodexConfigs, enabled = true): CodexConfigs {.raises: [].} =
  ## output log in stdout for all nodes in group
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.debugEnabled = enabled
  return startConfig

proc withLogFile*(
    self: CodexConfigs, idx: int
): CodexConfigs {.raises: [CodexConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--log-file", "<updated_in_test>")
  return startConfig

proc withLogFile*(self: CodexConfigs): CodexConfigs {.raises: [CodexConfigError].} =
  ## typically called from test, sets config such that a log file should be
  ## created
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--log-file", "<updated_in_test>")
  return startConfig

proc withLogFile*(
    self: var CodexConfig, logFile: string
) {.raises: [CodexConfigError].} = #: CodexConfigs =
  ## typically called internally from the test suite, sets a log file path to
  ## be created during the test run, for a specified node in the group
  # var config = self
  self.addCliOption("--log-file", logFile)
  # return startConfig

proc withLogLevel*(
    self: CodexConfig, level: LogLevel | string
): CodexConfig {.raises: [CodexConfigError].} =
  var config = self
  config.addCliOption("--log-level", $level)
  return config

proc withLogLevel*(
    self: CodexConfigs, idx: int, level: LogLevel | string
): CodexConfigs {.raises: [CodexConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--log-level", $level)
  return startConfig

proc withLogLevel*(
    self: CodexConfigs, level: LogLevel | string
): CodexConfigs {.raises: [CodexConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--log-level", $level)
  return startConfig

proc withSimulateProofFailures*(
    self: CodexConfigs, idx: int, failEveryNProofs: int
): CodexConfigs {.raises: [CodexConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption(
    StartUpCmd.persistence, "--simulate-proof-failures", $failEveryNProofs
  )
  return startConfig

proc withSimulateProofFailures*(
    self: CodexConfigs, failEveryNProofs: int
): CodexConfigs {.raises: [CodexConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption(
      StartUpCmd.persistence, "--simulate-proof-failures", $failEveryNProofs
    )
  return startConfig

proc withValidationGroups*(
    self: CodexConfigs, groups: ValidationGroups
): CodexConfigs {.raises: [CodexConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption(StartUpCmd.persistence, "--validator-groups", $(groups))
  return startConfig

proc withValidationGroupIndex*(
    self: CodexConfigs, idx: int, groupIndex: uint16
): CodexConfigs {.raises: [CodexConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption(
    StartUpCmd.persistence, "--validator-group-index", $groupIndex
  )
  return startConfig

proc withEthProvider*(
    self: CodexConfigs, idx: int, ethProvider: string
): CodexConfigs {.raises: [CodexConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption(
    StartUpCmd.persistence, "--eth-provider", ethProvider
  )
  return startConfig

proc withEthProvider*(
    self: CodexConfigs, ethProvider: string
): CodexConfigs {.raises: [CodexConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption(StartUpCmd.persistence, "--eth-provider", ethProvider)
  return startConfig

proc logLevelWithTopics(
    config: CodexConfig, topics: varargs[string]
): string {.raises: [CodexConfigError].} =
  convertError:
    var logLevel = LogLevel.INFO
    let built = config.buildConfig("Invalid codex config cli params")
    logLevel = parseEnum[LogLevel](built.logLevel.toUpperAscii)
    let level = $logLevel & ";TRACE: " & topics.join(",")
    return level

proc withLogTopics*(
    self: CodexConfigs, idx: int, topics: varargs[string]
): CodexConfigs {.raises: [CodexConfigError].} =
  self.checkBounds idx

  convertError:
    let config = self.configs[idx]
    let level = config.logLevelWithTopics(topics)
    var startConfig = self
    return startConfig.withLogLevel(idx, level)

proc withLogTopics*(
    self: CodexConfigs, topics: varargs[string]
): CodexConfigs {.raises: [CodexConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    let level = config.logLevelWithTopics(topics)
    config = config.withLogLevel(level)
  return startConfig

proc withStorageQuota*(
    self: CodexConfigs, idx: int, quota: NBytes
): CodexConfigs {.raises: [CodexConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--storage-quota", $quota)
  return startConfig

proc withStorageQuota*(
    self: CodexConfigs, quota: NBytes
): CodexConfigs {.raises: [CodexConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--storage-quota", $quota)
  return startConfig
