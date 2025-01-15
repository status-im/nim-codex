import pkg/stint

func fromDecimal*(T: typedesc[StUint | StInt], s: string): T {.inline.} =
  parse(s, type result, radix = 10)
