import pkg/stint
import pkg/contractabi
import pkg/ethers/fields

type
  Groth16Proof* = object
    a*: G1Point
    b*: G2Point
    c*: G1Point

  G1Point* = object
    x*: UInt256
    y*: UInt256

  # A field element F_{p^2} encoded as `real + i * imag`
  Fp2Element* = object
    real*: UInt256
    imag*: UInt256

  G2Point* = object
    x*: Fp2Element
    y*: Fp2Element

func solidityType*(_: type G1Point): string =
  solidityType(G1Point.fieldTypes)

func solidityType*(_: type Fp2Element): string =
  solidityType(Fp2Element.fieldTypes)

func solidityType*(_: type G2Point): string =
  solidityType(G2Point.fieldTypes)

func solidityType*(_: type Groth16Proof): string =
  solidityType(Groth16Proof.fieldTypes)

func encode*(encoder: var AbiEncoder, point: G1Point) =
  encoder.write(point.fieldValues)

func encode*(encoder: var AbiEncoder, element: Fp2Element) =
  encoder.write(element.fieldValues)

func encode*(encoder: var AbiEncoder, point: G2Point) =
  encoder.write(point.fieldValues)

func encode*(encoder: var AbiEncoder, proof: Groth16Proof) =
  encoder.write(proof.fieldValues)
