use "collections"
use "logger"
use "lori"
use "ssl/crypto"

// States for the barnyard -> postgres direction (we are the client talking to a
// real postgres backend).
//
// Stateless states are primitives — a state transition to one of them costs
// no allocation. Only states carrying per-connection or per-frame data are
// classes.

class _BarnyardClientStartup is _BarnyardConnectionWriterState
  let _backend_info: _BarnyardBackendInfo val

  new create(backend_info: _BarnyardBackendInfo val) =>
    _backend_info = backend_info

  fun write(conn: _BarnyardConnection ref): _BarnyardConnectionState box =>
    conn.send(_PgWire.client_startup(_backend_info.username, _backend_info.database))
    _Arm(conn, 5)
    _BarnyardClientAwaitAuth(_backend_info)

class _BarnyardClientAwaitAuth is _BarnyardConnectionReaderState
  let _backend_info: _BarnyardBackendInfo val

  new create(backend_info: _BarnyardBackendInfo val) =>
    _backend_info = backend_info

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    match _FrameHeader.parse(data)
    | (let msg_type: U8, let body_len: USize) =>
      if msg_type != 'R' then conn.hard_close(); return this end  // expected auth msg
      _Arm(conn, body_len)
      _BarnyardClientAuthBody(_backend_info)
    | None =>
      conn.hard_close()
      this
    end

class _BarnyardClientAuthBody is _BarnyardConnectionReaderState
  let _backend_info: _BarnyardBackendInfo val

  new create(backend_info: _BarnyardBackendInfo val) =>
    _backend_info = backend_info

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    let r = IterReader(data)
    try
      let code = r.u32_be()?
      match code
      | 0 =>
        conn.log()(Fine) and conn.log().log("backend auth OK")
        _Arm(conn, 5)
        _BarnyardClientAwaitParameterStatus   // backend epilogue begins
      | 3 =>
        conn.log()(Fine) and conn.log().log("backend requested cleartext password")
        conn.send(_PgWire.password_message(_backend_info.password))
        // send PasswordMessage 'p' with password, then await next 'R'
        _Arm(conn, 5)
        _BarnyardClientAwaitAuth(_backend_info)              // server replies with another 'R' (expect 0)
      | 5 =>
        conn.log()(Fine) and conn.log().log("backend requested MD5 password")
        let salt: String = String.from_iso_array(r.block(4)?)
        conn.send(_PgWire.password_message("md5" + ToHexString(MD5(ToHexString(MD5(_backend_info.password + _backend_info.username)) + salt))))
        _Arm(conn, 5)
        _BarnyardClientAwaitAuth(_backend_info)
      else
        conn.log()(Error) and conn.log().log("unsupported backend auth code: " + code.string())
        conn.hard_close()
        this
      end
    else
      conn.hard_close()
      this
    end

primitive _BarnyardClientAwaitParameterStatus is _BarnyardConnectionReaderState
  // header reader: peel type + length, go read the body
  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    match _FrameHeader.parse(data)
    | (let msg_type: U8, let body_len: USize) =>
      _Arm(conn, body_len)
      _BarnyardClientEpilogueBody(msg_type)
    | None =>
      conn.hard_close()
      this
    end

class _BarnyardClientEpilogueBody is _BarnyardConnectionReaderState
  let _msg_type: U8

  new create(msg_type: U8) =>
    _msg_type = msg_type

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    let r = IterReader(data)
    match _msg_type
    | 'S' =>                          // ParameterStatus: key\0 value\0
      try
        let key: String val = String.from_iso_array(r.read_until('\0')?)
        let value: String val = String.from_iso_array(r.read_until('\0')?)
        conn.log()(Fine) and conn.log().log("backend param: " + key + " = " + value)
        conn.params()(key) = value
      end
      _Arm(conn, 5)
      _BarnyardClientAwaitParameterStatus   // keep reading epilogue
    | 'K' =>                          // BackendKeyData: pid + secret (8 bytes)
      try
        let pid = r.u32_be()?
        let secret = r.u32_be()?
        conn.log()(Fine) and conn.log().log("backend key: pid=" + pid.string())
        // stash pid/secret if you'll support CancelRequest later
      end
      _Arm(conn, 5)
      _BarnyardClientAwaitParameterStatus
    | 'Z' =>                          // ReadyForQuery: 1 status byte
      conn.log()(Fine) and conn.log().log("backend ready — handshake complete")
      conn.on_startup_complete()
      _Arm(conn, 5)
      _BarnyardClientAwaitQueryHeader   // park reading responses / relaying
    | 'E' =>                          // ErrorResponse — backend rejected something
      conn.log()(Error) and conn.log().log("backend error during startup")
      conn.hard_close()
      this
    else
      conn.hard_close()
      this
    end

primitive _BarnyardClientAwaitQueryHeader is _BarnyardConnectionReaderState
  fun resume(conn: _BarnyardConnection ref): _BarnyardConnectionState box =>
    _Arm(conn, 5)
    this

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    match _FrameHeader.parse(data)
    | (let msg_type: U8, let body_len: USize) =>
      _Arm(conn, body_len)
      _BarnyardClientAwaitQueryBody(msg_type)
    | None =>
      conn.hard_close()
      this
    end

primitive _BarnyardClientPiped is _BarnyardConnectionReaderState
  fun resume(conn: _BarnyardConnection ref): _BarnyardConnectionState box =>
    conn.buffer_until(Streaming)
    this

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    conn.pipe_send(data)
    this

  fun pump(conn: _BarnyardConnection ref, chunks: ByteSeq val): _BarnyardConnectionState box =>
    conn.send(chunks)
    this

  fun pump_many(conn: _BarnyardConnection ref, chunks: ByteSeqIter): _BarnyardConnectionState box =>
    // Multi-buffer frontend frames (header + body) go to the backend in a
    // single writev.
    conn.send(chunks)
    this

class _BarnyardClientAwaitQueryBody is _BarnyardConnectionReaderState
  let _msg_type: U8

  new create(msg_type: U8) =>
    _msg_type = msg_type

  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box =>
    conn.log()(Fine) and conn.log().log("idle backend message: type=" + _msg_type.string())
    _Arm(conn, 5)
    _BarnyardClientAwaitQueryHeader
