type CliOption* = object
  key*: string # option key, including `--`
  value*: string # option value

proc `$`*(option: CliOption): string =
  var res = option.key
  if option.value.len > 0:
    res &= "=" & option.value
  return res
