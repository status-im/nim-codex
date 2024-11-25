import pkg/ethers
import codex/contracts/deployment
import codex/conf
import codex/contracts

import ../asynctest
import ../checktest

type MockProvider = ref object of Provider
  chainId*: UInt256

method getChainId*(provider: MockProvider): Future[UInt256] {.async: (raises:[ProviderError]).} =
  return provider.chainId

proc configFactory(): CodexConf =
  CodexConf(
    cmd: StartUpCmd.persistence,
    nat: ValidIpAddress.init("127.0.0.1"),
    discoveryIp: ValidIpAddress.init(IPv4_any()),
    metricsAddress: ValidIpAddress.init("127.0.0.1"))

proc configFactory(marketplace: Option[EthAddress]): CodexConf =
  CodexConf(
    cmd: StartUpCmd.persistence,
    nat: ValidIpAddress.init("127.0.0.1"),
    discoveryIp: ValidIpAddress.init(IPv4_any()),
    metricsAddress: ValidIpAddress.init("127.0.0.1"),
    marketplaceAddress: marketplace)

asyncchecksuite "Deployment":
  let provider = MockProvider()

  test "uses conf value as priority":
    let deployment = Deployment.new(provider, configFactory(EthAddress.init("0x59b670e9fA9D0A427751Af201D676719a970aaaa")))
    provider.chainId = 1.u256

    let address = await deployment.address(Marketplace)
    check address.isSome
    check $(!address) == "0x59b670e9fa9d0a427751af201d676719a970aaaa"

  test "uses chainId hardcoded values as fallback":
    let deployment = Deployment.new(provider, configFactory())
    provider.chainId = 167005.u256

    let address = await deployment.address(Marketplace)
    check address.isSome
    check $(!address) == "0x948cf9291b77bd7ad84781b9047129addf1b894f"

  test "return none for unknown networks":
    let deployment = Deployment.new(provider, configFactory())
    provider.chainId = 1.u256

    let address = await deployment.address(Marketplace)
    check address.isNone

