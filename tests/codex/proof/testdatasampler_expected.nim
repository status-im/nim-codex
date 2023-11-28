# Snapshot of expected values for testdatasampler.

import std/strutils
import pkg/codex/proof/types

proc getExpectedCellBlockProofs*(): seq[string] =
  @[
    "9863C3BE0A21CC49A03E3E7B4A134CBBE1F7A241EB61BFAE7478080A4B84E338EC99F9EE1D95A2F6126CE5FD7476E85790A95E03F4D9B63B827854CFF55F1E5236CA91969A70839AF19329616627803B29EA52185FFA8AE50FCC84C0BA8C69C4BA43F4397D2D50DD2982EDC3AF08E4762F34958645DC4749265DA9FC89874A86FFCEAB3B21F48386C75FCDA49656FE73F15C0E4AEE84479A880CA74817861A93",
    "1F6B7B8B46ACE123F53BBFBF96999B7EED1A4F07D2BA2831AF8855B312260D39D4E9996BD5F7FD83E293168DEC32B57AD08A54D38A748DD46FD21D2685A194087237F6493DD03FBA989C356E9BD35CF1E833E66E6FF06C212FF5FCB603E59AA762A338CE5CE3BD68D68E4A4A6C799FF935F3829085C86E07A12B27278E7A5AAD77CDFAD51D9B8B13C44646E01450D2140924211CBE62520B7C4916C4E4C955F5",
    "F2972FCDA69A1FF6B71BD487618FF1AB871C4D4861724F1B01574E414EB3C1D761CD0E8636D0CA8B899A070ABA5D9F815C6678877FAF71B984F5CF15300357E1C4C4A35D47EB0BECF6FB31E6C33CDB8A04D7EA0B29C2021678361F27CFBC96B355B36B13CC749463F14A7A0452A2F765E5951547B16CFB53D3824888226EE5D7FDB433239D7F55029C2C97C635A6B1214D1257C7D85C1C649758BA1AF8700E24"
  ]

proc getExpectedBlockSlotProofs*(): seq[string] =
  @[
    "9AB9952719B40E549953E197C1FF5DCCF2E20F18C2970A8E2CB455DE4CA462BEB77FD63AEB6A517F5AE514C8A9CCBAFED5500E595572018ECC9C4205F06140E8",
    "6ABAF89654125BBA9B99CA2635D605167D27D89641CE7E4ECF4F08E898C669B8DB784CEC822621E2DCB502F0135D48FEBACB228379FAC5ED295ED9F7A369107C",
    "6ABAF89654125BBA9B99CA2635D605167D27D89641CE7E4ECF4F08E898C669B8DB784CEC822621E2DCB502F0135D48FEBACB228379FAC5ED295ED9F7A369107C"
  ]

proc getExpectedCellData*(): seq[string] =
  @[
    "CA".repeat(CellSize),
    "A9".repeat(CellSize),
    "B3".repeat(CellSize)
  ]
