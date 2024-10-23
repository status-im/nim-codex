## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/algorithm
import std/sequtils

import pkg/chronos
import pkg/libp2p/[cid, multicodec, routing_record, signed_envelope]
import pkg/questionable
import pkg/questionable/results
import pkg/stew/shims/net
import pkg/contractabi/address as ca
import pkg/codexdht/discv5/[routing_table, protocol as discv5]

import ./rng
import ./errors
import ./logutils

export discv5

# TODO: If generics in methods had not been
# deprecated, this could have been implemented
# much more elegantly.

logScope:
  topics = "codex discovery"

type
  Discovery* = ref object of RootObj
    protocol*: discv5.Protocol          # dht protocol
    key: PrivateKey                     # private key
    peerId: PeerId                      # the peer id of the local node
    announceAddrs*: seq[MultiAddress]   # addresses announced as part of the provider records
    providerRecord*: ?SignedPeerRecord  # record to advertice node connection information, this carry any
                                        # address that the node can be connected on
    dhtRecord*: ?SignedPeerRecord       # record to advertice DHT connection information

proc toNodeId*(cid: Cid): NodeId =
  ## Cid to discovery id
  ##

  readUintBE[256](keccak256.digest(cid.data.buffer).data)

proc toNodeId*(host: ca.Address): NodeId =
  ## Eth address to discovery id
  ##

  readUintBE[256](keccak256.digest(host.toArray).data)

proc findPeer*(
  d: Discovery,
  peerId: PeerId): Future[?PeerRecord] {.async.} =
  trace "protocol.resolve..."
  ## Find peer using the given Discovery object
  ##
  let
    node = await d.protocol.resolve(toNodeId(peerId))

  return
    if node.isSome():
      node.get().record.data.some
    else:
      PeerRecord.none

method find*(
  d: Discovery,
  cid: Cid): Future[seq[SignedPeerRecord]] {.async, base.} =
  ## Find block providers
  ##
  without providers =?
    (await d.protocol.getProviders(cid.toNodeId())).mapFailure, error:
    warn "Error finding providers for block", cid, error = error.msg

  return providers.filterIt( not (it.data.peerId == d.peerId) )

method provide*(d: Discovery, cid: Cid) {.async, base.} =
  ## Provide a block Cid
  ##
  let
    nodes = await d.protocol.addProvider(
      cid.toNodeId(), d.providerRecord.get)

  if nodes.len <= 0:
    warn "Couldn't provide to any nodes!"


method find*(
  d: Discovery,
  host: ca.Address): Future[seq[SignedPeerRecord]] {.async, base.} =
  ## Find host providers
  ##

  trace "Finding providers for host", host = $host
  without var providers =?
    (await d.protocol.getProviders(host.toNodeId())).mapFailure, error:
    trace "Error finding providers for host", host = $host, exc = error.msg
    return

  if providers.len <= 0:
    trace "No providers found", host = $host
    return

  providers.sort do(a, b: SignedPeerRecord) -> int:
    system.cmp[uint64](a.data.seqNo, b.data.seqNo)

  return providers

method provide*(d: Discovery, host: ca.Address) {.async, base.} =
  ## Provide hosts
  ##

  trace "Providing host", host = $host
  let
    nodes = await d.protocol.addProvider(
      host.toNodeId(), d.providerRecord.get)
  if nodes.len > 0:
    trace "Provided to nodes", nodes = nodes.len

method removeProvider*(
  d: Discovery,
  peerId: PeerId): Future[void] {.base.} =
  ## Remove provider from providers table
  ##

  trace "Removing provider", peerId
  d.protocol.removeProvidersLocal(peerId)

proc updateAnnounceRecord*(d: Discovery, addrs: openArray[MultiAddress]) =
  ## Update providers record
  ##

  d.announceAddrs = @addrs

  trace "Updating announce record", addrs = d.announceAddrs
  d.providerRecord = SignedPeerRecord.init(
    d.key, PeerRecord.init(d.peerId, d.announceAddrs))
      .expect("Should construct signed record").some

  if not d.protocol.isNil:
    d.protocol.updateRecord(d.providerRecord)
      .expect("Should update SPR")

proc updateDhtRecord*(d: Discovery, ip: ValidIpAddress, port: Port) =
  ## Update providers record
  ##

  trace "Updating Dht record", ip, port = $port
  d.dhtRecord = SignedPeerRecord.init(
    d.key, PeerRecord.init(d.peerId, @[
      MultiAddress.init(
        ip,
        IpTransportProtocol.udpProtocol,
        port)])).expect("Should construct signed record").some

  if not d.protocol.isNil:
    d.protocol.updateRecord(d.dhtRecord)
      .expect("Should update SPR")

proc start*(d: Discovery) {.async.} =
  d.protocol.open()
  await d.protocol.start()

proc stop*(d: Discovery) {.async.} =
  await d.protocol.closeWait()

proc new*(
    T: type Discovery,
    key: PrivateKey,
    bindIp = ValidIpAddress.init(IPv4_any()),
    bindPort = 0.Port,
    announceAddrs: openArray[MultiAddress],
    bootstrapNodes: openArray[SignedPeerRecord] = [],
    store: Datastore = SQLiteDatastore.new(Memory).expect("Should not fail!")
): Discovery =
  ## Create a new Discovery node instance for the given key and datastore
  ##

  var
    self = Discovery(
      key: key,
      peerId: PeerId.init(key).expect("Should construct PeerId"))

  self.updateAnnounceRecord(announceAddrs)

  # --------------------------------------------------------------------------
  # FIXME disable IP limits temporarily so we can run our workshop. Re-enable
  #   and figure out proper solution.
  let discoveryConfig = DiscoveryConfig(
    tableIpLimits: TableIpLimits(
      tableIpLimit: high(uint),
      bucketIpLimit:high(uint)
    ),
    bitsPerHop: DefaultBitsPerHop
  )
  # --------------------------------------------------------------------------

  self.protocol = newProtocol(
    key,
    bindIp = bindIp.toNormalIp,
    bindPort = bindPort,
    record = self.providerRecord.get,
    bootstrapRecords = bootstrapNodes,
    rng = Rng.instance(),
    providers = ProvidersManager.new(store),
    config = discoveryConfig)

  self
