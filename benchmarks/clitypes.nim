import pkg/stint
import pkg/circomcompat
# import pkg/serde/json
import std/json

export stint, json

type
  CircomG1* = G1
  CircomG2* = G2

  CircomProof*  = Proof
  CircomKey*    = VerifyingKey
  CircomInputs* = Inputs

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

func `%`*(integer: UInt256): JsonNode =
  %($(integer))

func toG1*(g: CircomG1): G1Point =
  G1Point(
    x: UInt256.fromBytesLE(g.x),
    y: UInt256.fromBytesLE(g.y))

func toG2*(g: CircomG2): G2Point =
  G2Point(
    x: Fp2Element(
      real: UInt256.fromBytesLE(g.x[0]),
      imag: UInt256.fromBytesLE(g.x[1])
    ),
    y: Fp2Element(
      real: UInt256.fromBytesLE(g.y[0]),
      imag: UInt256.fromBytesLE(g.y[1])
    ))

func toGroth16Proof*(proof: CircomProof): Groth16Proof =
  Groth16Proof(
    a: proof.a.toG1,
    b: proof.b.toG2,
    c: proof.c.toG1)

proc parseBigInt*(input: JsonNode): UInt256 = 
  parse( input.str, UInt256 )
