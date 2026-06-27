use "collections"
use "buffered"
use "lori"

// States for the psql -> stable direction (we are impersonating a postgres
// backend to an incoming client).

class _StableServerAwaitLength is _StableConnectionReaderState
  let _out: OutStream

  new create(out: OutStream) =>
    _out = out

  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box =>
    let r = Reader .> append(consume data)
    try
      let len = r.u32_be()?.usize()
      if len < 8 then conn.hard_close(); return this end
      _out.print("Server: header says " + len.string() + " byte payload")
      _Arm(conn, 4)
      _StableServerAwaitDiscriminator(_out, len)
    else
      conn.hard_close()
      this
    end


class _StableServerAwaitDiscriminator is _StableConnectionReaderState
  let _out: OutStream
  let _len: USize

  new create(out: OutStream, len: USize) =>
    _out = out
    _len = len

  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box =>
    let r = Reader .> append(consume data)
    try
      let disc = r.u32_be()?
      if (disc == _Pg.ssl()) or (disc == _Pg.gss()) then
        conn.send("N")        // decline; 'S' if you support TLS
        _Arm(conn, 4)
        _StableServerAwaitLength(_out)                    // loop: real startup follows
      elseif disc == _Pg.v3() then
        let rest = _len - 8                   // length + version already consumed
        if rest == 0 then conn.hard_close(); return this end
        _Arm(conn, rest)
        _out.print("Transitioning to startup params")
        _StableServerAwaitStartupParams(_out)
      else
        conn.hard_close(); this
      end
    else
      conn.hard_close(); this
    end

class _StableServerAwaitStartupParams is _StableConnectionReaderState
  let _out: OutStream
  new create(out: OutStream) => _out = out

  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box =>
    let r = Reader .> append(consume data)
    let params = conn.params()
    try
      while true do
        let key = String.from_iso_array(r.read_until('\0')?)
        let value = String.from_iso_array(r.read_until('\0')?)
        params.insert(consume key, consume value)
      end
    end
    _out.print("startup complete")
    _StableServerAuthChallenge(_out)

class _StableServerAuthChallenge is _StableConnectionWriterState
  let _out: OutStream
  new create(out: OutStream) => _out = out

  fun write(conn: _StableConnection ref): _StableConnectionState box =>
    // Authentication OK, bullshit for now
    let msg = _PgWire.authentication_ok()
    _out.print("Sending OK auth challenge, default to trust")
    conn.send(msg)

    _StableServerParameterStatus(_out)

class _StableServerParameterStatus is _StableConnectionWriterState
  let _out: OutStream
  new create(out: OutStream) => _out = out

  fun write(conn: _StableConnection ref): _StableConnectionState box =>
    // Authentication OK, bullshit for now
    conn.send(_PgWire.parameter_status("server_version", "15.0"))
    conn.send(_PgWire.parameter_status("client_encoding", "UTF8"))
    conn.send(_PgWire.parameter_status("standard_conforming_strings", "on"))
    conn.send(_PgWire.parameter_status("DateStyle", "ISO, MDY"))

    _out.print("Sending server params")

    _StableServerBackendKeyData(_out)

class _StableServerBackendKeyData is _StableConnectionWriterState
  let _out: OutStream
  new create(out: OutStream) => _out = out

  fun write(conn: _StableConnection ref): _StableConnectionState box =>
    conn.send(_PgWire.backend_key_data(123, 456))
    _out.print("Sending PID and secret")

    _StableServerReadyIndicator(_out)

class _StableServerReadyIndicator is _StableConnectionWriterState
  let _out: OutStream
  new create(out: OutStream) => _out = out

  fun write(conn: _StableConnection ref): _StableConnectionState box =>
    conn.send(_PgWire.ready_for_query('I'))
    _out.print("Sending ready")

    _Arm(conn, 5)

    conn.on_startup_complete()
    _StableServerAwaitQueryHeader(_out)

class _StableServerAwaitQueryHeader is _StableConnectionReaderState
  let _out: OutStream
  new create(out: OutStream) => _out = out

  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box =>
    let r = Reader .> append(consume data)
    try
      let msg_type = r.u8()?
      let len = r.u32_be()?.usize()
      if len < 4 then conn.hard_close(); return this end  // underflow guard
      let body_len = len - 4
      _Arm(conn, body_len)
      _StableServerAwaitQueryBody(_out, msg_type)
    else
      conn.hard_close()
      this
    end

class _StableServerAwaitQueryBody is _StableConnectionReaderState
  let _out: OutStream
  let _msg_type: U8
  new create(out: OutStream, msg_type: U8) =>
    _out = out
    _msg_type = msg_type

  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box =>
    let r = Reader .> append(consume data)
    if _msg_type == 'Q' then
      try
        let sql = String.from_iso_array(r.read_until('\0')?)
        _out.print("Query: " + (consume sql))
      end
      // minimal response: CommandComplete + ReadyForQuery
      conn.send(_PgWire.command_complete("SET"))
      conn.send(_PgWire.ready_for_query('I'))
    elseif _msg_type == 'X' then
      // Terminate — psql closing the connection
      conn.close()
    end
    _Arm(conn, 5)                                  // back to reading a header
    _StableServerAwaitQueryHeader(_out)
