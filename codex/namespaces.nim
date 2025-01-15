## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

const
  # Namespaces
  CodexMetaNamespace* = "meta" # meta info stored here
  CodexRepoNamespace* = "repo" # repository namespace, blocks and manifests are subkeys
  CodexBlockTotalNamespace* = CodexMetaNamespace & "/total"
    # number of blocks in the repo
  CodexBlocksNamespace* = CodexRepoNamespace & "/blocks" # blocks namespace
  CodexManifestNamespace* = CodexRepoNamespace & "/manifests" # manifest namespace
  CodexBlocksTtlNamespace* = # Cid TTL
    CodexMetaNamespace & "/ttl"
  CodexBlockProofNamespace* = # Cid and Proof
    CodexMetaNamespace & "/proof"
  CodexDhtNamespace* = "dht" # Dht namespace
  CodexDhtProvidersNamespace* = # Dht providers namespace
    CodexDhtNamespace & "/providers"
  CodexQuotaNamespace* = CodexMetaNamespace & "/quota" # quota's namespace
