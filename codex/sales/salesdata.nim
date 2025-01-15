import pkg/chronos
import ../contracts/requests
import ../market
import ./reservations

type SalesData* = ref object
  requestId*: RequestId
  ask*: StorageAsk
  request*: ?StorageRequest
  slotIndex*: UInt256
  cancelled*: Future[void]
  reservation*: ?Reservation
