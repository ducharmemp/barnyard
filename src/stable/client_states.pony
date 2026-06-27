use "collections"
use "buffered"
use "lori"
use "ssl/crypto"

// States for the stable -> postgres direction (we are the client talking to a
// real postgres backend).

class _StableClientStartup is _StableConnectionWriterState
  let _backend_info: _StableBackendInfo val
  let _out: OutStream

  new create(backend_info: _StableBackendInfo val, out: OutStream) =>
    _backend_info = backend_info
    _out = out

  fun write(conn: _StableConnection ref): _StableConnectionState box =>
    conn.send(_PgWire.client_startup(_backend_info.username, _backend_info.database))
    _Arm(conn, 5)
    _StableClientAwaitAuth(_backend_info, _out)

class _StableClientAwaitAuth is _StableConnectionReaderState
  let _backend_info: _StableBackendInfo val
  let _out: OutStream

  new create(backend_info: _StableBackendInfo val, out: OutStream) =>
    _backend_info = backend_info
    _out = out

  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box =>
    let r = Reader .> append(consume data)
    try
      let msg_type = r.u8()?
      let len = r.u32_be()?.usize()
      if len < 4 then conn.hard_close(); return this end
      let body_len = len - 4
      if msg_type != 'R' then conn.hard_close(); return this end  // expected auth msg
      _Arm(conn, body_len)
      _StableClientAuthBody(_backend_info, _out)
    else
      conn.hard_close()
      this
    end

class _StableClientAuthBody is _StableConnectionReaderState
  let _backend_info: _StableBackendInfo val
  let _out: OutStream

  new create(backend_info: _StableBackendInfo val, out: OutStream) =>
    _backend_info = backend_info
    _out = out

  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box =>
    let r = Reader .> append(consume data)
    try
      let code = r.u32_be()?
      match code
      | 0 =>
        _out.print("Auth OK")
        _Arm(conn, 5)
        _StableClientAwaitParameterStatus(_out)   // backend epilogue begins
      | 3 =>
        _out.print("Cleartext password requested")
        conn.send(_PgWire.password_message(_backend_info.password))
        // send PasswordMessage 'p' with password, then await next 'R'
        _Arm(conn, 5)
        _StableClientAwaitAuth(_backend_info, _out)              // server replies with another 'R' (expect 0)
      | 5 =>
        _out.print("MD5 password requested")
        // body also has a 4-byte salt: let salt = r.block(4)?
        // conn.send(_PgWire.password_message(md5(...)))
        let salt: String = String.from_iso_array(r.block(4)?)
        conn.send(_PgWire.password_message("md5" + ToHexString(MD5(ToHexString(MD5(_backend_info.password + _backend_info.username)) + salt))))
        _Arm(conn, 5)
        _StableClientAwaitAuth(_backend_info, _out)
      else
        _out.print("Unsupported auth code: " + code.string())
        conn.hard_close()
        this
      end
    else
      conn.hard_close()
      this
    end

class _StableClientAwaitParameterStatus is _StableConnectionReaderState
  let _out: OutStream
  new create(out: OutStream) =>
    _out = out

  // header reader: peel type + length, go read the body
  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box =>
    let r = Reader .> append(consume data)
    try
      let msg_type = r.u8()?
      let len = r.u32_be()?.usize()
      if len < 4 then conn.hard_close(); return this end
      let body_len = len - 4
      _Arm(conn, body_len)
      _StableClientEpilogueBody(_out, msg_type)
    else
      conn.hard_close()
      this
    end

class _StableClientEpilogueBody is _StableConnectionReaderState
  let _out: OutStream
  let _msg_type: U8
  new create(out: OutStream, msg_type: U8) =>
    _out = out
    _msg_type = msg_type

  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box =>
    let r = Reader .> append(consume data)
    match _msg_type
    | 'S' =>                          // ParameterStatus: key\0 value\0
      try
        let key: String val = String.from_iso_array(r.read_until('\0')?)
        let value: String val = String.from_iso_array(r.read_until('\0')?)
        _out.print("Backend param: " + key + " = " + value)
        conn.params()(key) = value
      end
      _Arm(conn, 5)
      _StableClientAwaitParameterStatus(_out)   // keep reading epilogue
    | 'K' =>                          // BackendKeyData: pid + secret (8 bytes)
      try
        let pid = r.u32_be()?
        let secret = r.u32_be()?
        _out.print("Backend key: pid=" + pid.string())
        // stash pid/secret if you'll support CancelRequest later
      end
      _Arm(conn, 5)
      _StableClientAwaitParameterStatus(_out)
    | 'Z' =>                          // ReadyForQuery: 1 status byte
      _out.print("Backend ready — handshake complete")
      // conn._on_ready()  ← backend is now poolable
      _Arm(conn, 5)
      _StableClientAwaitQueryHeader(_out)   // park reading responses / relaying
    | 'E' =>                          // ErrorResponse — backend rejected something
      _out.print("Backend error during startup")
      conn.hard_close()
      this
    else
      conn.hard_close()
      this
    end

class _StableClientAwaitQueryHeader is _StableConnectionReaderState
  let _out: OutStream
  new create(out: OutStream) => _out = out

  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box =>
    let r = Reader .> append(consume data)
    try
      let msg_type = r.u8()?
      let len = r.u32_be()?.usize()
      if len < 4 then conn.hard_close(); return this end
      let body_len = len - 4
      _Arm(conn, body_len)
      _StableClientAwaitQueryBody(_out, msg_type)
    else
      conn.hard_close()
      this
    end

class _StableClientAwaitQueryBody is _StableConnectionReaderState
  let _out: OutStream
  let _msg_type: U8
  new create(out: OutStream, msg_type: U8) =>
    _out = out
    _msg_type = msg_type

  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box =>
    let r = Reader .> append(consume data)
    _out.print("Backend message body: type=" + _msg_type.string())
    _Arm(conn, 5)
    _StableClientAwaitQueryHeader(_out)
