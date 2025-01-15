## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/codex/discovery
import pkg/contractabi/address as ca

type MockDiscovery* = ref object of Discovery
  findBlockProvidersHandler*:
    proc(d: MockDiscovery, cid: Cid): Future[seq[SignedPeerRecord]] {.gcsafe.}
  publishBlockProvideHandler*: proc(d: MockDiscovery, cid: Cid): Future[void] {.gcsafe.}
  findHostProvidersHandler*:
    proc(d: MockDiscovery, host: ca.Address): Future[seq[SignedPeerRecord]] {.gcsafe.}
  publishHostProvideHandler*:
    proc(d: MockDiscovery, host: ca.Address): Future[void] {.gcsafe.}

proc new*(T: type MockDiscovery): MockDiscovery =
  MockDiscovery()

proc findPeer*(d: Discovery, peerId: PeerId): Future[?PeerRecord] {.async.} =
  ## mock find a peer - always return none
  ## 
  return none(PeerRecord)

method find*(d: MockDiscovery, cid: Cid): Future[seq[SignedPeerRecord]] {.async.} =
  if isNil(d.findBlockProvidersHandler):
    return

  return await d.findBlockProvidersHandler(d, cid)

method provide*(d: MockDiscovery, cid: Cid): Future[void] {.async.} =
  if isNil(d.publishBlockProvideHandler):
    return

  await d.publishBlockProvideHandler(d, cid)

method find*(
    d: MockDiscovery, host: ca.Address
): Future[seq[SignedPeerRecord]] {.async.} =
  if isNil(d.findHostProvidersHandler):
    return

  return await d.findHostProvidersHandler(d, host)

method provide*(d: MockDiscovery, host: ca.Address): Future[void] {.async.} =
  if isNil(d.publishHostProvideHandler):
    return

  await d.publishHostProvideHandler(d, host)
