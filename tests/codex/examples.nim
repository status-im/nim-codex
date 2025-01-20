import std/random
import std/sequtils
import pkg/libp2p
import pkg/nitro
import pkg/stint
import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/sales
import pkg/codex/merkletree
import ../examples

export examples

proc example*(_: type EthAddress): EthAddress =
  EthPrivateKey.random().toPublicKey.toAddress

proc example*(_: type UInt48): UInt48 =
  # workaround for https://github.com/nim-lang/Nim/issues/17670
  uint64.rand mod (UInt48.high + 1)

proc example*(_: type Wallet): Wallet =
  Wallet.init(EthPrivateKey.random())

proc example*(_: type WalletRef): WalletRef =
  WalletRef.new(EthPrivateKey.random())

proc example*(_: type SignedState): SignedState =
  var wallet = Wallet.example
  let hub, asset, receiver = EthAddress.example
  let chainId, amount = UInt256.example
  let nonce = UInt48.example
  let channel = wallet.openLedgerChannel(hub, chainId, nonce, asset, amount).get
  wallet.pay(channel, asset, receiver, amount).get

proc example*(_: type Pricing): Pricing =
  Pricing(
    address: EthAddress.example,
    price: uint32.rand.u256
  )

proc example*(_: type bt.Block): bt.Block =
  let length = rand(4096)
  let bytes = newSeqWith(length, rand(uint8))
  bt.Block.new(bytes).tryGet()

proc example*(_: type PeerId): PeerId =
  let key = PrivateKey.random(Rng.instance[]).get
  PeerId.init(key.getPublicKey().get).get

proc example*(_: type BlockExcPeerCtx): BlockExcPeerCtx =
  BlockExcPeerCtx(id: PeerId.example)

proc example*(_: type Cid): Cid =
  bt.Block.example.cid

proc example*(_: type MultiHash, mcodec = Sha256HashCodec): MultiHash =
  let bytes = newSeqWith(256, rand(uint8))
  MultiHash.digest($mcodec, bytes).tryGet()

proc example*(_: type Availability): Availability =
  let totalSize = uint16.example.u256
  let assumedCollateralPerByte = 1.u256
  Availability.init(
    totalSize = totalSize,
    freeSize = uint16.example.u256,
    duration = uint16.example.u256,
    minPricePerBytePerSecond = 1.u256,
    totalRemainingCollateral = totalSize * assumedCollateralPerByte
  )

proc example*(_: type Reservation): Reservation =
  Reservation.init(
    availabilityId = AvailabilityId(array[32, byte].example),
    size = uint16.example.u256,
    slotId = SlotId.example
  )

proc example*(_: type MerkleProof): MerkleProof =
  MerkleProof.init(3, @[MultiHash.example]).tryget()

proc example*(_: type Poseidon2Proof): Poseidon2Proof =
  var example = MerkleProof[Poseidon2Hash, PoseidonKeysEnum]()
  example.index = 123
  example.path = @[1, 2, 3, 4].mapIt( it.toF )
  example
