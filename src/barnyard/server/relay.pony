use "../connection"
use "../wire"
use "logger"

primitive BarnyardServerUnbound is BarnyardConnectionReaderState
  fun name(): String => "ServerUnbound"

  fun enter(conn: BarnyardConnection ref) =>
    conn.unmute()
    ArmStream(conn)

  fun read(conn: BarnyardConnection ref, data: ByteSeq val): BarnyardConnectionTransition box =>
    // An idle client that's done sends a bare Terminate ('X'). It must NOT pull a
    // backend from the pool — that backend would be bound to a dying client and
    // leaked. 'X' is an unambiguous frontend message type, so a leading 'X' means
    // Terminate: close the client side directly. Anything else is a real query,
    // so acquire a backend and hold the bytes until one arrives.
    let bytes = _AsBytes(data)
    try
      if bytes(0)? == 'X' then
        return BarnyardConnectionClose
      end
    end
    conn.established()
    BarnyardServerAcquiring(data)

class BarnyardServerAcquiring is BarnyardConnectionIdleState
  let _held: ByteSeq val

  new create(held: ByteSeq val) =>
    _held = held

  fun name(): String => "ServerAcquiring"

  fun enter(conn: BarnyardConnection ref) =>
    conn.mute()

  fun wake(conn: BarnyardConnection ref, backend: BarnyardConnection tag)
    : BarnyardConnectionTransition box
  =>
    // frame the first client bytes just as ServerBound would (a large first
    // query may straddle the acquire boundary), then relay to the backend
    _RelayFrames(conn, backend, _AsBytes(_held), ScanBetween)

// Relays the client<->backend byte stream. Inbound (client->PG) bytes are passed
// straight through, except a Terminate ('X') message, which must NOT reach
// Postgres — forwarding it would close the pooled backend. Terminate ends the
// client side instead. A frame split across reads is held, never partially
// forwarded (so a split Terminate can't leak, and a large query frames
// continuously).
//
// Outbound (PG->client) bytes are relayed to the client AND scanned for the
// ReadyForQuery that ends the transaction. At an 'I' boundary the server
// releases its backend and re-acquires for the next query; at 'T'/'E' it stays
// bound. The backend observes the same 'I' independently and returns itself to
// the pool, so there is no boundary signal between the two actors to race.
class BarnyardServerBound is BarnyardConnectionPipingState
  let _peer: BarnyardConnection tag
  let _held: Array[U8] val    // inbound: a partial client frame awaiting its tail
  let _out: ScanPosition      // outbound: where the ReadyForQuery walk resumes

  new create(peer: BarnyardConnection tag, held: Array[U8] val = _NoBytes(),
    out: ScanPosition = ScanBetween)
  =>
    _peer = peer
    _held = held
    _out = out

  fun name(): String => "ServerBound"

  fun enter(conn: BarnyardConnection ref) =>
    conn.unmute()
    ArmStream(conn)

  fun read(conn: BarnyardConnection ref, data: ByteSeq val): BarnyardConnectionTransition box =>
    let bytes =
      if _held.size() == 0 then _AsBytes(data)
      else Cat(_held, _AsBytes(data))
      end
    _RelayFrames(conn, _peer, bytes, _out)

  fun pipe(conn: BarnyardConnection ref, chunks: ForwardData): BarnyardConnectionTransition box =>
    conn.send(chunks)
    match ResponseScan(_ForwardBytes(chunks), _out)
    | let r: ScanReady =>
      if r.status == 'I' then
        // transaction done: drop our backend and re-acquire on the next query
        BarnyardServerUnbound
      else
        // 'T'/'E': still inside a transaction, keep this backend
        BarnyardServerBound(_peer, _held, ScanBetween)
      end
    | let c: ScanContinue =>
      BarnyardServerBound(_peer, _held, c.position)
    | ScanMalformed =>
      conn.log()(Error) and conn.log().log("server: malformed backend response")
      BarnyardConnectionHardClose
    end

  fun closed(conn: BarnyardConnection ref) =>
    // client gone: hand our backend back to the pool
    _peer.release()

primitive _RelayFrames
  fun apply(conn: BarnyardConnection ref, peer: BarnyardConnection tag,
    bytes: Array[U8] val, out: ScanPosition): BarnyardConnectionTransition box
  =>
    var at: USize = 0
    while (at + 5) <= bytes.size() do
      match FrameHeader.parse_at(bytes, at)
      | ('X', _) =>
        // Terminate: forward everything before it, then close the client only.
        if at > 0 then peer.forward(bytes.trim(0, at)) end
        return BarnyardConnectionClose
      | (_, let body_len: USize) =>
        let next = at + 5 + body_len
        if next > bytes.size() then break end
        at = next
      | None =>
        conn.log()(Error) and conn.log().log("client: bad frame header")
        return BarnyardConnectionHardClose
      end
    end
    // forward the run of complete frames; hold any incomplete tail
    if at > 0 then peer.forward(bytes.trim(0, at)) end
    BarnyardServerBound(peer, bytes.trim(at), out)

primitive _AsBytes
  fun apply(data: ByteSeq val): Array[U8] val =>
    match data
    | let s: String => s.array()
    | let a: Array[U8] val => a
    end

primitive _ForwardBytes
  fun apply(data: ForwardData): Array[U8] val =>
    match data
    | let s: String => s.array()
    | let a: Array[U8] val => a
    | let parts: Array[ByteSeq] val =>
      recover val
        let out = Array[U8]
        for p in parts.values() do
          match p
          | let s: String => out.append(s)
          | let b: Array[U8] val => out.append(b)
          end
        end
        out
      end
    end

primitive _NoBytes
  fun apply(): Array[U8] val => recover val Array[U8] end
