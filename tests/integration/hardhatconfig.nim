type HardhatConfig* = object
  logFile*: bool
  debugEnabled*: bool

proc debug*(self: HardhatConfig, enabled = true): HardhatConfig =
  ## output log in stdout
  var config = self
  config.debugEnabled = enabled
  return config

proc withLogFile*(self: HardhatConfig, logToFile: bool = true): HardhatConfig =
  var config = self
  config.logFile = logToFile
  return config
