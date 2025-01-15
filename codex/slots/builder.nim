import ./builder/builder
import ./converters

import ../merkletree

export builder, converters

type Poseidon2Builder* = SlotsBuilder[Poseidon2Tree, Poseidon2Hash]
