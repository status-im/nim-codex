import ./sampler/sampler
import ./sampler/utils

import ../merkletree

export sampler, utils

type Poseidon2Sampler* = DataSampler[Poseidon2Tree, Poseidon2Hash]
