import pkg/questionable
import ./codexconfig
import ./hardhatconfig

type NodeConfigs* = object
  clients*: ?CodexConfigs
  providers*: ?CodexConfigs
  validators*: ?CodexConfigs
  hardhat*: ?HardhatConfig
