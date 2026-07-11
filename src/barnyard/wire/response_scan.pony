// Scans a Postgres backend response stream for the ReadyForQuery frame that ends
// a transaction, without buffering: a caller forwards bytes as they arrive and
// threads the returned position back on the next chunk. Both sides of the proxy
// use it as independent observers of the same protocol truth — the backend to
// decide when it may return to the pool, the server to decide when to release
// its backend and re-acquire — so neither has to signal the other at a boundary.

primitive ScanBetween
  """At a frame boundary."""

primitive ScanAtStatus
  """Consumed a ReadyForQuery header; the next byte is its status ('I'/'T'/'E')."""

class val ScanMidHeader
  """Partway through a 5-byte frame header."""
  let sofar: Array[U8] val
  new val create(sofar': Array[U8] val) => sofar = sofar'

class val ScanMidBody
  """Partway through a frame body; this many bytes remain."""
  let remaining: USize
  new val create(remaining': USize) => remaining = remaining'

type ScanPosition is (ScanBetween | ScanAtStatus | ScanMidHeader | ScanMidBody)

class val ScanReady
  """Reached a ReadyForQuery frame carrying this transaction-status byte."""
  let status: U8
  new val create(status': U8) => status = status'

class val ScanContinue
  """Consumed the whole chunk; resume the walk here on the next chunk."""
  let position: ScanPosition
  new val create(position': ScanPosition) => position = position'

primitive ScanMalformed
  """A frame header did not parse; the stream is corrupt."""

type ScanResult is (ScanReady | ScanContinue | ScanMalformed)

primitive ResponseScan
  fun apply(bytes: Array[U8] val, resume: ScanPosition): ScanResult =>
    let size = bytes.size()
    var at: USize = 0

    match resume
    | ScanBetween => None
    | let m: ScanMidBody =>
      if m.remaining > size then
        return ScanContinue(ScanMidBody(m.remaining - size))
      end
      at = m.remaining
    | ScanAtStatus =>
      return _resolve(bytes, 0, size)
    | let h: ScanMidHeader =>
      let need = 5 - h.sofar.size()
      if size < need then
        return ScanContinue(ScanMidHeader(Cat(h.sofar, bytes)))
      end
      match FrameHeader.parse(Cat(h.sofar, bytes.trim(0, need)))
      | ('Z', 1) => return _resolve(bytes, need, size)
      | ('Z', _) => return ScanMalformed
      | (_, let bl: USize) =>
        if (need + bl) > size then
          return ScanContinue(ScanMidBody((need + bl) - size))
        end
        at = need + bl
      | None => return ScanMalformed
      end
    end

    while (at + 5) <= size do
      match FrameHeader.parse_at(bytes, at)
      | ('Z', 1) => return _resolve(bytes, at + 5, size)
      | ('Z', _) => return ScanMalformed
      | (_, let bl: USize) =>
        let next = at + 5 + bl
        if next > size then
          return ScanContinue(ScanMidBody(next - size))
        end
        at = next
      | None => return ScanMalformed
      end
    end

    if at < size then
      ScanContinue(ScanMidHeader(bytes.trim(at)))
    else
      ScanContinue(ScanBetween)
    end

  fun _resolve(bytes: Array[U8] val, status_at: USize, size: USize): ScanResult =>
    if status_at >= size then
      return ScanContinue(ScanAtStatus)
    end
    try
      ScanReady(bytes(status_at)?)
    else
      ScanMalformed
    end
