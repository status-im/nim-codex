## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/tables
import std/algorithm

import pkg/upraises

push: {.upraises: [].}

import pkg/chronos
import pkg/libp2p

import ../protobuf/blockexc
import ../../blocktype
import ../../logutils


import ./peercontext
export peercontext

logScope:
  topics = "codex peerctxstore"

type
  PeerCtxStore* = ref object of RootObj
    peers*: OrderedTable[PeerId, BlockExcPeerCtx]

iterator items*(self: PeerCtxStore): BlockExcPeerCtx =
  for p in self.peers.values:
    yield p

proc contains*(a: openArray[BlockExcPeerCtx], b: PeerId): bool =
  ## Convenience method to check for peer precense
  ##

  a.anyIt( it.id == b )

func contains*(self: PeerCtxStore, peerId: PeerId): bool =
  peerId in self.peers

func add*(self: PeerCtxStore, peer: BlockExcPeerCtx) =
  self.peers[peer.id] = peer

func remove*(self: PeerCtxStore, peerId: PeerId) =
  self.peers.del(peerId)

func get*(self: PeerCtxStore, peerId: PeerId): BlockExcPeerCtx =
  self.peers.getOrDefault(peerId, nil)

func len*(self: PeerCtxStore): int =
  self.peers.len

func peersHave*(self: PeerCtxStore, address: BlockAddress): seq[BlockExcPeerCtx] =
  toSeq(self.peers.values).filterIt( it.peerHave.anyIt( it == address ) )

func peersHave*(self: PeerCtxStore, cid: Cid): seq[BlockExcPeerCtx] =
  toSeq(self.peers.values).filterIt( it.peerHave.anyIt( it.cidOrTreeCid == cid ) )

func peersWant*(self: PeerCtxStore, address: BlockAddress): seq[BlockExcPeerCtx] =
  toSeq(self.peers.values).filterIt( it.peerWants.anyIt( it == address ) )

func peersWant*(self: PeerCtxStore, cid: Cid): seq[BlockExcPeerCtx] =
  toSeq(self.peers.values).filterIt( it.peerWants.anyIt( it.address.cidOrTreeCid == cid ) )

func selectCheapest*(self: PeerCtxStore, address: BlockAddress): seq[BlockExcPeerCtx] =
  # assume that the price for all leaves in a tree is the same
  let rootAddress = BlockAddress(leaf: false, cid: address.cidOrTreeCid)
  var peers = self.peersHave(rootAddress)

  func cmp(a, b: BlockExcPeerCtx): int =
    var
      priceA = 0.u256
      priceB = 0.u256

    a.blocks.withValue(rootAddress, precense):
      priceA = precense[].price

    b.blocks.withValue(rootAddress, precense):
      priceB = precense[].price

    if priceA == priceB:
      0
    elif priceA > priceB:
      1
    else:
      -1

  peers.sort(cmp)
  trace "Selected cheapest peers", peers = peers.len
  return peers

proc new*(T: type PeerCtxStore): PeerCtxStore =
  ## create new instance of a peer context store
  PeerCtxStore(peers: initOrderedTable[PeerId, BlockExcPeerCtx]())
