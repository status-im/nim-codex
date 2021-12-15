## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/sequtils

import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos
import pkg/presto
import pkg/libp2p
import pkg/stew/byteutils

import pkg/libp2p/routing_record

import ../node

proc validate(
  pattern: string,
  value: string): int {.gcsafe, raises: [Defect].} =
  0

proc encodeString(cid: type Cid): Result[string, cstring] =
  ok($cid)

proc decodeString(T: type Cid, value: string): Result[Cid, cstring] =
  let cid = Cid.init(value)
  if cid.isOk:
    ok(cid.get())
  else:
    case cid.error
    of CidError.Incorrect: err("Incorrect Cid")
    of CidError.Unsupported: err("Unsupported Cid")
    of CidError.Overrun: err("Overrun Cid")
    else: err("Error parsing Cid")

proc encodeString(peerId: PeerID): Result[string, cstring] =
  ok($peerId)

proc decodeString(T: type PeerID, value: string): Result[PeerID, cstring] =
  let peer = PeerID.init(value)
  if peer.isOk:
    ok(peer.get())
  else:
    err(peer.error())

proc encodeString(address: MultiAddress): Result[string, cstring] =
  ok($address)

proc decodeString(T: type MultiAddress, value: string): Result[MultiAddress, cstring] =
  let address = MultiAddress.init(value)
  if address.isOk:
    ok(address.get())
  else:
    err(cstring(address.error()))

proc initRestApi*(node: DaggerNodeRef): RestRouter =
  var router = RestRouter.init(validate)
  router.api(
    MethodGet,
    "/api/dagger/v1/download/{id}") do (
      id: Cid, resp: HttpResponseRef) -> RestApiResponse:
      if id.isErr:
        return RestApiResponse.error(
          Http400,
          $id.error())

      let
        stream = BufferStream.new()

      var bytes = 0
      try:
        if (
            let retr = await node.retrieve(stream, id.get());
            retr.isErr):
            return RestApiResponse.error(Http400, retr.error.msg)

        await resp.prepareChunked()
        while not stream.atEof:
          var
            buff = newSeqUninitialized[byte](FileChunkSize)
            len = await stream.readOnce(addr buff[0], buff.len)

          buff.setLen(len)
          if buff.len <= 0:
            break

          bytes += buff.len
          trace "Sending cunk", size = buff.len
          await resp.sendChunk(addr buff[0], buff.len)
      except CatchableError as exc:
        trace "Excepting streaming blocks", exc = exc.msg
        return RestApiResponse.error(Http500)
      finally:
        trace "Sent bytes", cid = id.get(), bytes
        await stream.close()
        await resp.finish()

  router.api(
    MethodGet,
    "/api/dagger/v1/connect/{peerId}") do (
      peerId: PeerID,
      addrs: seq[MultiAddress]) -> RestApiResponse:
      if peerId.isErr:
        return RestApiResponse.error(
          Http400,
          $peerId.error())

      let addresess = if addrs.isOk and addrs.get().len > 0:
            addrs.get()
          else:
            let peerRecord = await node.findPeer(peerId.get())
            if peerRecord.isErr:
              return RestApiResponse.error(
                Http400,
                "Unable to find Peer!")

            peerRecord.get().addresses.mapIt(
              it.address
            )

      await node.connect(peerId.get(), addresess)
      return RestApiResponse.response("")

  router.rawApi(
    MethodPost,
    "/api/dagger/v1/upload") do (
    ) -> RestApiResponse:
      trace "Handling file upload"
      var bodyReader = request.getBodyReader()
      if bodyReader.isErr():
        return RestApiResponse.error(Http500)

      var reader = bodyReader.get()
      try:
        # Attempt to handle `Expect` header
        # some clients (curl), waits 1000ms
        # before giving up
        #
        await request.handleExpect()

        var
          bytes = 0
          stream = BufferStream.new()
          storeFut = node.store(stream)

        try:
          while not reader.atEof:
            var
              buff = newSeqUninitialized[byte](FileChunkSize)
              len = await reader.readOnce(addr buff[0], buff.len)

            buff.setLen(len)
            if len <= 0:
              break

            trace "Got chunk from endpoint", len = buff.len
            await stream.pushData(buff)
            bytes += len
        finally:
          await stream.pushEof()
          await reader.closeWait()

        without cid =? (await storeFut):
          return RestApiResponse.error(Http500)

        await stream.close()
        trace "Uploaded file", bytes, cid = $cid
        return RestApiResponse.response($cid)
      except CancelledError as exc:
        if not(isNil(reader)):
          await reader.closeWait()
        return RestApiResponse.error(Http500)
      except AsyncStreamError:
        if not(isNil(reader)):
          await reader.closeWait()
        return RestApiResponse.error(Http500)

      # if we got here something went wrong?
      return RestApiResponse.error(Http500)

  return router
