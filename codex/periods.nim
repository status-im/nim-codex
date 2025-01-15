import pkg/stint

type
  Periodicity* = object
    seconds*: UInt256

  Period* = UInt256
  Timestamp* = UInt256

func periodOf*(periodicity: Periodicity, timestamp: Timestamp): Period =
  timestamp div periodicity.seconds

func periodStart*(periodicity: Periodicity, period: Period): Timestamp =
  period * periodicity.seconds

func periodEnd*(periodicity: Periodicity, period: Period): Timestamp =
  periodicity.periodStart(period + 1)
