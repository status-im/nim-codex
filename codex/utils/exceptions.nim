import std/strformat

proc msgDetail*(e: ref CatchableError): string =
  var msg = e.msg
  if e.parent != nil:
    msg = fmt"{msg} Inner exception: {e.parent.msg}"
  return msg
