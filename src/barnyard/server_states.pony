use "buffered"
use "collections"
use "logger"
use "lori"

// States for the psql -> barnyard direction (we are impersonating a postgres
// backend to an incoming client).
//
// Stateless states are primitives — a state transition to one of them costs
// no allocation. Only states carrying per-frame data are classes.

primitive _BarnyardServerAwaitLength is _BarnyardConnectionReaderState
  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    let r = Reader
    r.append(data)
    try
      let len = r.u32_be()?.usize()
      if len < 8 then conn.hard_close(); return this end
      conn.log()(Fine) and conn.log().log("startup: header says " + len.string() + " byte payload")
      _Arm(conn, 4)
      _BarnyardServerAwaitDiscriminator(len)
    else
      conn.hard_close()
      this
    end

class _BarnyardServerAwaitDiscriminator is _BarnyardConnectionReaderState
  let _len: USize

  new create(len: USize) =>
    _len = len

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    let r = Reader
    r.append(data)
    try
      let disc = r.u32_be()?
      if (disc == _Pg.ssl()) or (disc == _Pg.gss()) then
        conn.send("N")        // decline; 'S' if you support TLS
        _Arm(conn, 4)
        _BarnyardServerAwaitLength             // loop: real startup follows
      elseif disc == _Pg.v3() then
        let rest = _len - 8                   // length + version already consumed
        if rest == 0 then conn.hard_close(); return this end
        _Arm(conn, rest)
        _BarnyardServerAwaitStartupParams
      else
        conn.hard_close(); this
      end
    else
      conn.hard_close(); this
    end

primitive _BarnyardServerAwaitStartupParams is _BarnyardConnectionReaderState
  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    let r = Reader
    r.append(data)
    let params = conn.params()
    try
      while true do
        let key = String.from_iso_array(r.read_until('\0')?)
        let value = String.from_iso_array(r.read_until('\0')?)
        params.insert(consume key, consume value)
      end
    end
    conn.log()(Fine) and conn.log().log("client startup params received")
    _BarnyardServerAuthChallenge

primitive _BarnyardServerAuthChallenge is _BarnyardConnectionWriterState
  fun write(conn: _BarnyardConnection ref): _BarnyardConnectionState box =>
    // Authentication OK, bullshit for now
    conn.send(_PgWire.authentication_ok())
    _BarnyardServerParameterStatus

primitive _BarnyardServerParameterStatus is _BarnyardConnectionWriterState
  fun write(conn: _BarnyardConnection ref): _BarnyardConnectionState box =>
    conn.send(_PgWire.parameter_status("server_version", "15.0"))
    conn.send(_PgWire.parameter_status("client_encoding", "UTF8"))
    conn.send(_PgWire.parameter_status("standard_conforming_strings", "on"))
    conn.send(_PgWire.parameter_status("DateStyle", "ISO, MDY"))
    _BarnyardServerBackendKeyData

primitive _BarnyardServerBackendKeyData is _BarnyardConnectionWriterState
  fun write(conn: _BarnyardConnection ref): _BarnyardConnectionState box =>
    conn.send(_PgWire.backend_key_data(123, 456))
    _BarnyardServerReadyIndicator

primitive _BarnyardServerReadyIndicator is _BarnyardConnectionWriterState
  fun write(conn: _BarnyardConnection ref): _BarnyardConnectionState box =>
    conn.send(_PgWire.ready_for_query('I'))
    conn.log()(Fine) and conn.log().log("client handshake complete")
    _Arm(conn, 5)
    conn.on_startup_complete()
    _BarnyardServerAwaitQueryHeader

primitive _BarnyardServerBatch
  """
  Frontend frame classification for the batch-until-Sync lease model.

  A lease spans a client batch: every frontend frame up to and including
  one that makes the backend eventually answer with ReadyForQuery — simple
  Query ('Q'), extended-protocol Sync ('S'), or FunctionCall ('F').
  Extended-protocol frames before Sync (Parse/Bind/Describe/Execute/...)
  are forwarded without awaiting a response.
  """
  fun ends_batch(msg_type: U8): Bool =>
    (msg_type == 'Q') or (msg_type == 'S') or (msg_type == 'F')

  fun ends_copy(msg_type: U8): Bool =>
    (msg_type == 'c') or (msg_type == 'f')   // CopyDone / CopyFail

primitive _BarnyardServerForward
  """
  Route to the next state after a frontend frame header. The raw header
  bytes were staged by the caller exactly as they arrived — frames are
  never rebuilt — and the accumulated batch goes to the backend in a
  single writev at the batch boundary.
  """
  fun apply(conn: _BarnyardConnection ref, msg_type: U8, body_len: USize,
    in_copy: Bool): _BarnyardConnectionState box
  =>
    if body_len == 0 then
      next(conn, msg_type, in_copy)
    else
      _Arm(conn, body_len.min(_MaxArm()))
      _BarnyardServerForwardQueryBody(msg_type, body_len, in_copy)
    end

  fun next(conn: _BarnyardConnection ref, msg_type: U8, in_copy: Bool)
    : _BarnyardConnectionState box
  =>
    let batch_over =
      if in_copy then
        _BarnyardServerBatch.ends_copy(msg_type)
      else
        _BarnyardServerBatch.ends_batch(msg_type)
      end
    if batch_over then
      _await_response(conn)
    else
      if msg_type == 'H' then
        // Flush: the client expects the backend to answer mid-batch, so
        // everything staged must reach it now.
        conn.flush_pipe()
      end
      if in_copy then
        _BarnyardServerCopyInForward.resume(conn)
      else
        _BarnyardServerAwaitQueryHeader.resume(conn)
      end
    end

  fun _await_response(conn: _BarnyardConnection ref): _BarnyardConnectionState box =>
    // The batch reaches the backend as one writev; responses flow back
    // while the frontend stays muted.
    conn.flush_pipe()
    _ArmForMute(conn)
    conn.mute()
    _BarnyardServerAwaitBackendResponse

primitive _BarnyardServerAwaitQueryHeader is _BarnyardConnectionReaderState
  fun resume(conn: _BarnyardConnection ref): _BarnyardConnectionState box =>
    _Arm(conn, 5)
    this

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    match _FrameHeader.parse(data)
    | (let msg_type: U8, let body_len: USize) =>
      if msg_type == 'X' then
        conn.close()
        return this
      end
      conn.stage(data)
      if conn.has_backend() then
        // Mid-batch, or a sticky in-transaction lease: the backend is
        // already paired, no pool round trip needed.
        _BarnyardServerForward(conn, msg_type, body_len, false)
      else
        _ArmForMute(conn)
        conn.mute()
        conn.acquire_backend()
        _BarnyardServerAwaitBackend(msg_type, body_len)
      end
    | None =>
      conn.hard_close()
      this
    end

  fun pump(conn: _BarnyardConnection ref, chunks: ByteSeq val): _BarnyardConnectionState box =>
    // Between batches the backend can still speak: responses to Flush and
    // async messages (notices, parameter changes). Relay them.
    conn.send(chunks)
    this

class _BarnyardServerAwaitBackend is _BarnyardConnectionReaderState
  """
  Muted while the pool acquire for the batch's first frame is in flight.
  Carries that frame's header so forwarding can continue on resume.
  """
  let _msg_type: U8
  let _body_len: USize

  new create(msg_type: U8, body_len: USize) =>
    _msg_type = msg_type
    _body_len = body_len

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    // Unreachable while muted.
    this

  fun resume(conn: _BarnyardConnection ref): _BarnyardConnectionState box =>
    conn.unmute()
    _BarnyardServerForward(conn, _msg_type, _body_len, false)

class _BarnyardServerForwardQueryBody is _BarnyardConnectionReaderState
  """
  Stages a frontend frame body for the backend, in read-buffer-sized pieces
  when the body exceeds lori's buffer-until ceiling. Chunks are staged raw
  — zero copy — and reach the backend when the batch flushes (or earlier
  via the staging auto-flush).
  """
  let _msg_type: U8
  let _remaining: USize
  let _in_copy: Bool

  new create(msg_type: U8, remaining: USize, in_copy: Bool) =>
    _msg_type = msg_type
    _remaining = remaining
    _in_copy = in_copy

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    conn.stage(data)
    let remaining = _remaining - data.size()
    if remaining == 0 then
      _BarnyardServerForward.next(conn, _msg_type, _in_copy)
    else
      _Arm(conn, remaining.min(_MaxArm()))
      _BarnyardServerForwardQueryBody(_msg_type, remaining, _in_copy)
    end

  fun pump(conn: _BarnyardConnection ref, chunks: ByteSeq val): _BarnyardConnectionState box =>
    // The backend can error mid-batch (e.g. a failed Parse) while a body is
    // still arriving. Relay it; the client sorts itself out at Sync.
    conn.send(chunks)
    this

primitive _BarnyardServerCopyInForward is _BarnyardConnectionReaderState
  """
  COPY FROM STDIN: the backend sent CopyInResponse, so the frontend now
  streams CopyData frames. Forward them until CopyDone/CopyFail, then mute
  and await the backend's CommandComplete + ReadyForQuery.
  """
  fun resume(conn: _BarnyardConnection ref): _BarnyardConnectionState box =>
    _Arm(conn, 5)
    this

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    match _FrameHeader.parse(data)
    | (let msg_type: U8, let body_len: USize) =>
      if msg_type == 'X' then
        conn.close()
        return this
      end
      conn.stage(data)
      _BarnyardServerForward(conn, msg_type, body_len, true)
    | None =>
      conn.hard_close()
      this
    end

  fun pump(conn: _BarnyardConnection ref, chunks: ByteSeq val): _BarnyardConnectionState box =>
    // Errors and notices the backend raises mid-copy go to the client.
    conn.send(chunks)
    this

primitive _BarnyardServerAwaitBackendResponse is _BarnyardConnectionReaderState
  """
  Fresh response-await: frame walking starts at a message boundary. The
  common case — a whole response in one chunk, ending in ReadyForQuery —
  enters and leaves this primitive without allocating a state. Only when a
  frame straddles the chunk boundary does the walk continue in a
  _BarnyardServerResponseCarry instance.
  """
  fun pump(conn: _BarnyardConnection ref, chunks: ByteSeq val): _BarnyardConnectionState box =>
    _BarnyardServerResponseWalk(conn, chunks, 0, 0, 0, 0, false, false)

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    // Unreachable while muted.
    this

class _BarnyardServerResponseCarry is _BarnyardConnectionReaderState
  """
  Mid-frame continuation of the response walk: header progress and
  remaining body bytes carried across a chunk boundary.
  """
  let _hdr_n: USize   // header bytes consumed so far (0..4)
  let _hdr_type: U8   // frame type byte, valid once _hdr_n >= 1
  let _hdr_len: U32   // frame length accumulator, complete at _hdr_n == 5
  let _skip: USize    // body bytes left to relay in the current frame
  let _is_rfq: Bool   // current frame is ReadyForQuery
  let _is_copy: Bool  // current frame is CopyInResponse

  new create(hdr_n': USize, hdr_type': U8, hdr_len': U32,
    skip': USize, is_rfq': Bool, is_copy': Bool)
  =>
    _hdr_n = hdr_n'
    _hdr_type = hdr_type'
    _hdr_len = hdr_len'
    _skip = skip'
    _is_rfq = is_rfq'
    _is_copy = is_copy'

  fun pump(conn: _BarnyardConnection ref, chunks: ByteSeq val): _BarnyardConnectionState box =>
    _BarnyardServerResponseWalk(conn, chunks,
      _hdr_n, _hdr_type, _hdr_len, _skip, _is_rfq, _is_copy)

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    // Unreachable while muted.
    this

primitive _BarnyardServerResponseWalk
  """
  Relays backend response bytes to the psql client while walking postgres
  message frames. Bodies are skipped by their declared length rather than
  scanned, so a 'Z 00 00 00 05' pattern inside row data can't false-positive
  as ReadyForQuery, and large results cost O(frames) instead of O(bytes).

  Returns the state to continue in: a fresh await when the chunk ended on a
  frame boundary, a carry when a frame straddled it, the query-header state
  after ReadyForQuery closes the batch, or copy-in forwarding after a
  CopyInResponse.
  """
  fun apply(conn: _BarnyardConnection ref, chunks: ByteSeq val,
    hdr_n': USize, hdr_type': U8, hdr_len': U32,
    skip': USize, is_rfq': Bool, is_copy': Bool): _BarnyardConnectionState box
  =>
    let data: Array[U8] val = match chunks
    | let s: String => s.array()
    | let a: Array[U8] val => a
    end
    let n = data.size()
    var i: USize = 0
    var hdr_n = hdr_n'
    var hdr_type = hdr_type'
    var hdr_len = hdr_len'
    var skip = skip'
    var is_rfq = is_rfq'
    var is_copy = is_copy'

    try
      while i < n do
        if skip > 0 then
          // Mid-body: bytes just relay. Only two frame types change course
          // as their body completes.
          if is_rfq then
            return _finish_batch(conn, chunks, data(i)?)
          end
          let take = skip.min(n - i)
          skip = skip - take
          i = i + take
          if (skip == 0) and is_copy then
            return _begin_copy_in(conn, chunks)
          end
        else
          // Accumulate the 5-byte header: type byte, then big-endian length.
          let b = data(i)?
          i = i + 1
          if hdr_n == 0 then
            hdr_type = b
          else
            hdr_len = (hdr_len << 8) or b.u32()
          end
          hdr_n = hdr_n + 1
          if hdr_n == 5 then
            let malformed = (hdr_len < 4)
              or ((hdr_type == 'Z') and (hdr_len != 5)) // RFQ: 1 status byte
            if malformed then
              conn.hard_close()
              return _BarnyardServerAwaitBackendResponse
            end
            skip = (hdr_len - 4).usize()
            is_rfq = hdr_type == 'Z'
            is_copy = hdr_type == 'G'
            hdr_n = 0
            hdr_type = 0
            hdr_len = 0
          end
        end
      end
    end

    conn.send(chunks)
    if (hdr_n == 0) and (skip == 0) then
      // Chunk ended exactly on a frame boundary: nothing to carry.
      _BarnyardServerAwaitBackendResponse
    else
      _BarnyardServerResponseCarry(hdr_n, hdr_type, hdr_len, skip, is_rfq, is_copy)
    end

  fun _finish_batch(conn: _BarnyardConnection ref, chunks: ByteSeq val,
    status: U8): _BarnyardConnectionState box
  =>
    """
    ReadyForQuery's status byte closes the batch. Idle ('I') releases the
    backend; 'T'/'E' keep the lease sticky so the rest of the transaction
    reaches the same backend.
    """
    conn.send(chunks)
    if status == 'I' then
      conn.release_backend()
    end
    conn.unmute()
    _BarnyardServerAwaitQueryHeader.resume(conn)

  fun _begin_copy_in(conn: _BarnyardConnection ref, chunks: ByteSeq val)
    : _BarnyardConnectionState box
  =>
    """
    CopyInResponse relayed in full: the frontend now streams the copy
    payload, so hand control back to it.
    """
    conn.send(chunks)
    conn.unmute()
    _BarnyardServerCopyInForward.resume(conn)
