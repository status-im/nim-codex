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
  PeersForBlock* = object of RootObj
    with*: seq[BlockExcPeerCtx]
    without*: seq[BlockExcPeerCtx]

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

func countPeersWhoHave*(self: PeerCtxStore, cid: Cid): int =
  self.peers.values.countIt(it.peerHave.anyIt( it.cidOrTreeCid == cid ) )

func peersWant*(self: PeerCtxStore, address: BlockAddress): seq[BlockExcPeerCtx] =
  toSeq(self.peers.values).filterIt( it.peerWants.anyIt( it == address ) )

proc getPeersForBlock*(self: PeerCtxStore, address: BlockAddress): PeersForBlock =
  var res = PeersForBlock()
  for peer in self:
    if peer.peerHave.anyIt( it == address ):
      res.with.add(peer)
    else:
      res.without.add(peer)
  res

proc new*(T: type PeerCtxStore): PeerCtxStore =
  ## create new instance of a peer context store
  PeerCtxStore(peers: initOrderedTable[PeerId, BlockExcPeerCtx]())
