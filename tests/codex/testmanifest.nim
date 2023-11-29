import std/sequtils

import pkg/chronos
import pkg/questionable/results
import pkg/asynctest
import pkg/stew/byteutils

import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/manifest

import ./helpers
import ./examples

checksuite "Manifest":
  test "Should encode/decode to/from base manifest":
    var
      manifest = Manifest.new(
        treeCid = Cid.example,
        blockSize = 1.MiBs,
        datasetSize = 100.MiBs)

    let
      e = manifest.encode().tryGet()
      decoded = Manifest.decode(e).tryGet()

    check:
      decoded == manifest

  test "Should encode/decode to/from protected manifest":
    var
      manifest = Manifest.new(
        manifest = Manifest.new(
          treeCid = Cid.example,
          blockSize = 1.MiBs,
          datasetSize = 100.MiBs),
        treeCid = Cid.example,
        datasetSize = 200.MiBs,
        eck = 10,
        ecM = 10
      )

    let
      e = manifest.encode().tryGet()
      decoded = Manifest.decode(e).tryGet()

    check:
      decoded == manifest

  # test "Should encode/decode to/from verifiable manifest":
  #   var
  #     manifest = Manifest.new(
  #       manifest = Manifest.new(
  #         treeCid = Cid.example,
  #         blockSize = 1.MiBs,
  #         datasetSize = 100.MiBs),
  #       treeCid = Cid.example,
  #       datasetSize = 200.MiBs,
  #       eck = 10,
  #       ecM = 10
  #     )

  #   let
  #     e = manifest.encode().tryGet()
  #     decoded = Manifest.decode(e).tryGet()

  #   check:
  #     decoded == manifest
