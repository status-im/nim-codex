import pkg/chronos
import pkg/poseidon2
import pkg/poseidon2/io
import pkg/constantine/math/io/io_fields
import pkg/questionable/results
import pkg/codex/merkletree
import pkg/codex/slots/converters

import ../../asynctest
import ../examples
import ../merkletree/helpers

let hash: Poseidon2Hash = toF(12345)

suite "Converters":
  test "CellBlock cid":
    let
      cid = toCellCid(hash).tryGet()
      value = fromCellCid(cid).tryGet()

    check:
      hash.toDecimal() == value.toDecimal()

  test "Slot cid":
    let
      cid = toSlotCid(hash).tryGet()
      value = fromSlotCid(cid).tryGet()

    check:
      hash.toDecimal() == value.toDecimal()

  test "Verify cid":
    let
      cid = toVerifyCid(hash).tryGet()
      value = fromVerifyCid(cid).tryGet()

    check:
      hash.toDecimal() == value.toDecimal()

  test "Proof":
    let
      codexProof = toEncodableProof(Poseidon2Proof.example).tryGet()
      poseidonProof = toVerifiableProof(codexProof).tryGet()

    check:
      Poseidon2Proof.example == poseidonProof
