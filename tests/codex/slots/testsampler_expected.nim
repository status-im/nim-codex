# Snapshot of expected values for testsampler.

import std/strutils
import pkg/codex/codextypes

proc getExpectedCellBlockProofs*(): seq[string] =
  @[
    "0x25a5eb25b99ac58d637c44e776d235c14d4dd242692af5ee5f408321b09efe080x0a1917880f9a012ff69ecb78f2998686a8f52fb5ae5f7ba06bc1bf71fbb07a4f0x20cb422cbf0525bdc22c5d984fadf66f8a8e05e8e4a019424b30d3ee2a3ce4c00x0e85faef68f8933db587cb8807e31eb03e0ec8bfb9043bfddadcad1dde50f9790x0363952a6d08539ad707dbfb3bbcb249b1658fd1409c14ba4ee49e8a61c8a7ee",
    "0x1f0f029e9bc8044e3f06752d09cbc0d2c3c32579fcd38f074bae321d55465d2a0x15847d909cabdac1a9612cc3b62eaf3375aa7f0a6929dd1fbaed1bfeb39066ac0x11b677732d8a0d196a9fba82f4b2fa4eb549524504d6d3aacedf6bbb6d9356d90x27a362c0f92c887d74ee77df2df5e51f0f66b0564a2af8b1c11b02dab0a34f780x095eb3c0d166c19f9cac8ea0e6ba274dfeef802cf7d01c90378585fd4d788e56",
    "0x2aa17646c1b567df6775dedfdec1f22c775c7457d7d8452a6800cb3820fb77e70x2a48f8260d5757a8683ede9909dcff2f82ffa6343d39bd2d758fbec6ad0645710x199b5348b9d0ac6f9839b31fb38defcf811eefd29b8f7c95e615ac572e5a80c90x0e85faef68f8933db587cb8807e31eb03e0ec8bfb9043bfddadcad1dde50f9790x0363952a6d08539ad707dbfb3bbcb249b1658fd1409c14ba4ee49e8a61c8a7ee"
  ]

proc getExpectedBlockSlotProofs*(): seq[string] =
  @[
    "0x2120044583a9c578407f44da2acd0d0d15c656a28476c689103795855e40766e0x2a66917fa49371e835376fcece0d854c77008ac1195740963b1ac4491ee1aaf1",
    "0x2120044583a9c578407f44da2acd0d0d15c656a28476c689103795855e40766e0x2a66917fa49371e835376fcece0d854c77008ac1195740963b1ac4491ee1aaf1",
    "0x2120044583a9c578407f44da2acd0d0d15c656a28476c689103795855e40766e0x2a66917fa49371e835376fcece0d854c77008ac1195740963b1ac4491ee1aaf1"
  ]

proc getExpectedCellData*(): seq[string] =
  @[
    "61".repeat(DefaultCellSize.int),
    "7D".repeat(DefaultCellSize.int),
    "65".repeat(DefaultCellSize.int)
  ]