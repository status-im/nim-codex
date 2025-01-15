import pkg/chronicles
import pkg/questionable

export chronicles

type NodeConfig* = ref object of RootObj
  logFile*: bool
  logLevel*: ?LogLevel
  debugEnabled*: bool

proc debug*[T: NodeConfig](config: T, enabled = true): T =
  ## output log in stdout
  var startConfig = config
  startConfig.debugEnabled = enabled
  return startConfig

proc withLogFile*[T: NodeConfig](config: T, logToFile: bool = true): T =
  var startConfig = config
  startConfig.logFile = logToFile
  return startConfig

proc withLogLevel*[T: NodeConfig](config: NodeConfig, level: LogLevel): T =
  var startConfig = config
  startConfig.logLevel = some level
  return startConfig
