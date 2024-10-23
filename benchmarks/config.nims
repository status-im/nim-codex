--path:
  ".."
--path:
  "../tests"
--threads:
  on
--tlsEmulation:
  off
--d:
  release

# when not defined(chronicles_log_level):
#   --define:"chronicles_log_level:NONE" # compile all log statements
#   --define:"chronicles_sinks:textlines[dynamic]" # allow logs to be filtered at runtime
#   --"import":"logging" # ensure that logging is ignored at runtime
