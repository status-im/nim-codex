import pkg/constantine/platforms/abstractions

import pkg/codex/merkletree
import ../helpers

export merkletree, helpers

converter toBool*(x: CTBool): bool =
  bool(x)

proc `==`*(a, b: Poseidon2Tree): bool =
  (a.leavesCount == b.leavesCount) and (a.levels == b.levels) and (a.layers == b.layers)

proc `==`*(a, b: Poseidon2Proof): bool =
  (a.nleaves == b.nleaves) and (a.index == b.index) and (a.path.len == b.path.len) and
    (a.path == b.path)

proc `==`*(a, b: CodexTree): bool =
  (a.mcodec == b.mcodec) and (a.leavesCount == b.leavesCount) and (a.levels == b.levels)

proc `==`*(a, b: CodexProof): bool =
  (a.mcodec == b.mcodec) and (a.nleaves == b.nleaves) and (a.path == b.path) and
    (a.index == b.index)
