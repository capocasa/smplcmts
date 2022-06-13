
import times, asyncfutures, fusion/btreetables

# bolts redis-like expiry onto a key/value mapping

type
  Expiry*[T] = object
    index*: Table[Time, string]
    future*: Future[void]
    timer*: owned(Future[bool])
    store*: T

proc initExpiry[T](): Expiry =
  result

proc next(expiry: Expiry): Time =
  for time in expiry.index.keys:
    return time

proc expire[T](expiry: Expiry, key: string, time: Time) =
  set(expiry.store, "expiry $#" % key, $time.toUnixFloat)
  expiry.index[time] = key
  if expiry.next < time:
    expiry.future.cancel
    expiry.run

proc load[T](expiry: Expiry, store: T) =
  for key, time in expiry.store.items:
    expiry.index[time] = key

proc process(expiry): =
  let time = expiry.next
  let key = expiry.index[time]
  expiry.index.del(time)
  del(expiry.store, "expiry $#" % key)
  del(expiry.store, key)

proc run[T](expiry: Expiry, now: Time) =
  let time = expiry.next
  expiry.future.setCallback proc () = expiry.process
  expiry.timer = withTimeout(expiry.future, (time - now).asMilliseconds)
