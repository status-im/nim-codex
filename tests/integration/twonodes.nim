import std/os
import std/macros
import pkg/questionable
import ./multinodes
import ./codexconfig
import ./codexprocess
import ./codexclient
import ./nodeconfigs

export codexclient
export multinodes

template twonodessuite*(name: string, body: untyped) =
  multinodesuite name:
    let twoNodesConfig {.inject, used.} =
      NodeConfigs(clients: CodexConfigs.init(nodes = 2).some)

    var node1 {.inject, used.}: CodexProcess
    var node2 {.inject, used.}: CodexProcess
    var client1 {.inject, used.}: CodexClient
    var client2 {.inject, used.}: CodexClient
    var account1 {.inject, used.}: Address
    var account2 {.inject, used.}: Address

    setup:
      account1 = accounts[0]
      account2 = accounts[1]

      node1 = clients()[0]
      node2 = clients()[1]

      client1 = node1.client
      client2 = node2.client

    body
