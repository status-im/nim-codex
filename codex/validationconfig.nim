import std/strformat
import pkg/questionable
import pkg/questionable/results

type
  ValidationGroups* = range[2 .. 65535]
  MaxSlots* = int
  ValidationConfig* = object
    maxSlots: MaxSlots
    groups: ?ValidationGroups
    groupIndex: uint16

func init*(
    _: type ValidationConfig,
    maxSlots: MaxSlots,
    groups: ?ValidationGroups,
    groupIndex: uint16 = 0,
): ?!ValidationConfig =
  if maxSlots < 0:
    return failure "The value of maxSlots must be greater than " &
      fmt"or equal to 0! (got: {maxSlots})"
  if validationGroups =? groups and groupIndex >= uint16(validationGroups):
    return failure "The value of the group index must be less than " &
      fmt"validation groups! (got: {groupIndex = }, " & fmt"groups = {validationGroups})"

  success ValidationConfig(maxSlots: maxSlots, groups: groups, groupIndex: groupIndex)

func maxSlots*(config: ValidationConfig): MaxSlots =
  config.maxSlots

func groups*(config: ValidationConfig): ?ValidationGroups =
  config.groups

func groupIndex*(config: ValidationConfig): uint16 =
  config.groupIndex
