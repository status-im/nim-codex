import std/httpclient
import pkg/codex/contracts
import ./twonodes
import ../codex/examples
import ../contracts/time

proc findItem[T](items: seq[T], item: T): ?!T =
  for tmp in items:
    if tmp == item:
      return success tmp

  return failure("Not found")

twonodessuite "Sales", debug1 = false, debug2 = false:

  test "node handles new storage availability":
    let availability1 = client1.postAvailability(totalSize=1.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    let availability2 = client1.postAvailability(totalSize=4.u256, duration=5.u256, minPrice=6.u256, maxCollateral=7.u256).get
    check availability1 != availability2

  test "node lists storage that is for sale":
    let availability = client1.postAvailability(totalSize=1.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    check availability in client1.getAvailabilities().get

  test "updating non-existing availability":
    let nonExistingResponse = client1.patchAvailabilityRaw(AvailabilityId.example, duration=100.u256.some, minPrice=200.u256.some, maxCollateral=200.u256.some)
    check nonExistingResponse.status == "404 Not Found"

  test "updating availability":
    let availability = client1.postAvailability(totalSize=140000.u256, duration=200.u256, minPrice=300.u256, maxCollateral=300.u256).get

    client1.patchAvailability(availability.id, duration=100.u256.some, minPrice=200.u256.some, maxCollateral=200.u256.some)

    let updatedAvailability = (client1.getAvailabilities().get).findItem(availability).get
    check updatedAvailability.duration == 100
    check updatedAvailability.minPrice == 200
    check updatedAvailability.maxCollateral == 200
    check updatedAvailability.totalSize == 140000
    check updatedAvailability.freeSize == 140000

  test "updating availability - freeSize is not allowed to be changed":
    let availability = client1.postAvailability(totalSize=140000.u256, duration=200.u256, minPrice=300.u256, maxCollateral=300.u256).get
    let freeSizeResponse = client1.patchAvailabilityRaw(availability.id, freeSize=110000.u256.some)
    check freeSizeResponse.status == "400 Bad Request"
    check "not allowed" in  freeSizeResponse.body

  test "updating availability - updating totalSize":
    let availability = client1.postAvailability(totalSize=140000.u256, duration=200.u256, minPrice=300.u256, maxCollateral=300.u256).get
    client1.patchAvailability(availability.id, totalSize=100000.u256.some)
    let updatedAvailability = (client1.getAvailabilities().get).findItem(availability).get
    check updatedAvailability.totalSize == 100000
    check updatedAvailability.freeSize == 100000

  test "updating availability - updating totalSize does not allow bellow utilized":
    let originalSize = 0xFFFFFF.u256
    let data = await RandomChunker.example(blocks=8)
    let availability = client1.postAvailability(totalSize=originalSize, duration=20*60.u256, minPrice=300.u256, maxCollateral=300.u256).get

    # Lets create storage request that will utilize some of the availability's space
    let cid = client2.upload(data).get
    let id = client2.requestStorage(
      cid,
      duration=10*60.u256,
      reward=400.u256,
      proofProbability=3.u256,
      expiry=5*60,
      collateral=200.u256,
      nodes = 5,
      tolerance = 2).get

    check eventually(client2.purchaseStateIs(id, "started"), timeout=5*60*1000)
    let updatedAvailability = (client1.getAvailabilities().get).findItem(availability).get
    check updatedAvailability.totalSize != updatedAvailability.freeSize

    let utilizedSize = updatedAvailability.totalSize - updatedAvailability.freeSize
    let totalSizeResponse = client1.patchAvailabilityRaw(availability.id, totalSize=(utilizedSize-1.u256).some)
    check totalSizeResponse.status == "400 Bad Request"
    check "totalSize must be larger then current totalSize" in totalSizeResponse.body

    client1.patchAvailability(availability.id, totalSize=(originalSize + 20000).some)
    let newUpdatedAvailability = (client1.getAvailabilities().get).findItem(availability).get
    check newUpdatedAvailability.totalSize == originalSize + 20000
    check newUpdatedAvailability.freeSize - updatedAvailability.freeSize == 20000
