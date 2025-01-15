import std/hashes
import ../logutils

type PurchaseId* = distinct array[32, byte]

logutils.formatIt(LogFormat.textLines, PurchaseId):
  it.short0xHexLog
logutils.formatIt(LogFormat.json, PurchaseId):
  it.to0xHexLog

proc hash*(x: PurchaseId): Hash {.borrow.}
proc `==`*(x, y: PurchaseId): bool {.borrow.}
proc toHex*(x: PurchaseId): string =
  array[32, byte](x).toHex
