when not defined(nimscript):
  import pkg/codex/logutils

  proc ignoreLogging(level: LogLevel, message: LogOutputStr) =
    discard

  defaultChroniclesStream.output.writer = ignoreLogging

  {.warning[UnusedImport]: off.}
  {.used.}
