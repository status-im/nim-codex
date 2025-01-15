import std/options
import std/typetraits
from pkg/ethers import Address
from pkg/libp2p import
  Cid, PeerId, SignedPeerRecord, MultiAddress, AddressInfo, init, `$`
import pkg/contractabi
import pkg/codexdht/discv5/node as dn
import pkg/serde/json
import pkg/questionable/results
import ../errors

export json

proc fromJson*(_: type Cid, json: JsonNode): ?!Cid =
  expectJsonKind(Cid, JString, json)
  Cid.init(json.str).mapFailure

func `%`*(cid: Cid): JsonNode =
  % $cid

func `%`*(obj: PeerId): JsonNode =
  % $obj

func `%`*(obj: SignedPeerRecord): JsonNode =
  % $obj

func `%`*(obj: dn.Address): JsonNode =
  % $obj

func `%`*(obj: AddressInfo): JsonNode =
  % $obj.address

func `%`*(obj: MultiAddress): JsonNode =
  % $obj

func `%`*(address: ethers.Address): JsonNode =
  % $address
