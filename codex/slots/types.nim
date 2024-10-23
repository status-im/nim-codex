## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

type
  Sample*[H] = object
    cellData*: seq[H]
    merklePaths*: seq[H]

  PublicInputs*[H] = object
    slotIndex*: int
    datasetRoot*: H
    entropy*: H

  ProofInputs*[H] = object
    entropy*: H
    datasetRoot*: H
    slotIndex*: Natural
    slotRoot*: H
    nCellsPerSlot*: Natural
    nSlotsPerDataSet*: Natural
    slotProof*: seq[H]       # inclusion proof that shows that the slot root (leaf) is part of the dataset (root)
    samples*: seq[Sample[H]] # inclusion proofs which show that the selected cells (leafs) are part of the slot (roots)
