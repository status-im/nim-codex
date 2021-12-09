## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options

import pkg/questionable
import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/stew/byteutils

# TODO: remove once exported by libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/signed_envelope

import ./conf
import ./chunker
import ./blocktype
import ./blockset
import ./utils/asyncfutures
import ./stores/blockstore

const
  FileChunkSize* = 4096 # file chunk read size

type
  DaggerNodeRef* = ref object
    switch*: Switch
    config*: DaggerConf
    networkId*: PeerID
    blockStore*: BlockStore

proc start*(node: DaggerNodeRef) {.async.} =
  discard await node.switch.start()
  node.networkId = node.switch.peerInfo.peerId
  trace "Started dagger node", id = node.networkId, addrs = node.switch.peerInfo.addrs

proc stop*(node: DaggerNodeRef): Future[void] =
  node.switch.stop()

proc findPeer*(
  node: DaggerNodeRef,
  peerId: PeerID): Future[Result[PeerRecord, string]] {.async.} =
  discard

proc connect*(
  node: DaggerNodeRef,
  peerId: PeerID,
  addrs: seq[MultiAddress]): Future[void] =
  node.switch.connect(peerId, addrs)

proc retrieve*(
  node: DaggerNodeRef,
  cid: Cid): Future[LPStream] =
  discard

proc store*(
  node: DaggerNodeRef,
  stream: LPStream): Future[Cid] {.async.} =

  let
    blockSet = BlockSetRef.new()
    blocks = LPStreamChunker
    .new(stream)
    .toStream()
    .toStream()
    .toStream(blockSet)

  for b in blocks:
    await node.blockStore.putBlock((await b))

  without cid =? blockSet.treeHash():
    return default(Cid)

  return cid

proc new*(
  T: type DaggerNodeRef,
  switch: Switch,
  store: BlockStore,
  config: DaggerConf): T =
  T(
    switch: switch,
    config: config,
    blockStore: store)
