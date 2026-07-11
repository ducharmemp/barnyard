use "buffered"
use "logger"
use "ssl/crypto"
use "../connection"
use "../wire"

// States for the barnyard -> postgres direction (we are the client talking to a
// real postgres backend).

class BarnyardClientStartup is BarnyardConnectionWriterState
  let _backend_info: BarnyardBackendInfo val

  new create(backend_info: BarnyardBackendInfo val) =>
    _backend_info = backend_info

  fun name(): String => "ClientStartup"

  fun write(conn: BarnyardConnection ref): BarnyardConnectionTransition box =>
    conn.send(PgWire.client_startup(_backend_info.username, _backend_info.database))
    BarnyardClientAwaitAuth(_backend_info)

class BarnyardClientAwaitAuth is BarnyardConnectionReaderState
  let _backend_info: BarnyardBackendInfo val

  new create(backend_info: BarnyardBackendInfo val) =>
    _backend_info = backend_info

  fun name(): String => "ClientAwaitAuth"

  fun enter(conn: BarnyardConnection ref) =>
    Arm(conn, 5)

  fun read(conn: BarnyardConnection ref, data: ByteSeq val): BarnyardConnectionTransition box =>
    match FrameHeader.parse(data)
    | (let msg_type: U8, let body_len: USize) =>
      if msg_type != 'R' then
        conn.log()(Error) and conn.log().log("backend: expected auth message, got " + Char(msg_type))
        return BarnyardConnectionHardClose
      end
      BarnyardClientAuthBody(_backend_info, body_len)
    | None =>
      conn.log()(Error) and conn.log().log("backend: bad auth frame header")
      BarnyardConnectionHardClose
    end

class BarnyardClientAuthBody is BarnyardConnectionReaderState
  let _backend_info: BarnyardBackendInfo val
  let _body_len: USize

  new create(backend_info: BarnyardBackendInfo val, body_len: USize) =>
    _backend_info = backend_info
    _body_len = body_len

  fun name(): String => "ClientAuthBody"

  fun enter(conn: BarnyardConnection ref) =>
      Arm(conn, _body_len)

  fun read(conn: BarnyardConnection ref, data: ByteSeq val): BarnyardConnectionTransition box =>
    let r = Reader
    r.append(data)
    try
      let code = r.u32_be()?
      match code
      | 0 =>
        conn.log()(Fine) and conn.log().log("backend: auth ok")
        BarnyardClientAwaitParameterStatus   // backend epilogue begins
      | 3 =>
        conn.log()(Fine) and conn.log().log("backend: requested cleartext password")
        conn.send(PgWire.password_message(_backend_info.password))
        // send PasswordMessage 'p' with password, then await next 'R'
        BarnyardClientAwaitAuth(_backend_info)              // server replies with another 'R' (expect 0)
      | 5 =>
        conn.log()(Fine) and conn.log().log("backend: requested MD5 password")
        let salt: String = String.from_iso_array(r.block(4)?)
        conn.send(PgWire.password_message("md5" + ToHexString(MD5(ToHexString(MD5(_backend_info.password + _backend_info.username)) + salt))))
        BarnyardClientAwaitAuth(_backend_info)
      else
        conn.log()(Error) and conn.log().log("backend: unsupported auth code " + code.string())
        BarnyardConnectionHardClose
      end
    else
      conn.log()(Error) and conn.log().log("backend: short auth payload")
      BarnyardConnectionHardClose
    end

primitive BarnyardClientAwaitParameterStatus is BarnyardConnectionReaderState
  fun name(): String => "ClientAwaitParameterStatus"

  fun enter(conn: BarnyardConnection ref) =>
    Arm(conn, 5)

  // header reader: peel type + length, go read the body
  fun read(conn: BarnyardConnection ref, data: ByteSeq val): BarnyardConnectionTransition box =>
    match FrameHeader.parse(data)
    | (let msg_type: U8, let body_len: USize) =>
      conn.log()(Fine) and conn.log().log("backend: msg_type" + Char(msg_type) + " & body_len = " + body_len.string())
      BarnyardClientEpilogueBody(msg_type, body_len)
    | None =>
      conn.log()(Error) and conn.log().log("backend: bad frame header in startup epilogue")
      BarnyardConnectionHardClose
    end

class BarnyardClientEpilogueBody is BarnyardConnectionReaderState
  let _msg_type: U8
  let _body_len: USize

  new create(msg_type: U8, body_len: USize) =>
    _msg_type = msg_type
    _body_len = body_len

  fun name(): String => "ClientEpilogueBody"

  fun enter(conn: BarnyardConnection ref) =>
    ArmMax(conn, _body_len)

  fun read(conn: BarnyardConnection ref, data: ByteSeq val): BarnyardConnectionTransition box =>
    let r = Reader
    r.append(data)
    match _msg_type
    | 'S' =>                          // ParameterStatus: key\0 value\0
      try
        let key: String val = String.from_iso_array(r.read_until('\0')?)
        let value: String val = String.from_iso_array(r.read_until('\0')?)
        conn.log()(Fine) and conn.log().log("backend: param " + key + " = " + value)
        conn.on_param(key, value)
      else
        conn.log()(Warn) and conn.log().log("backend: malformed ParameterStatus body")
      end
      BarnyardClientAwaitParameterStatus   // keep reading epilogue
    | 'K' =>                          // BackendKeyData: pid + secret (8 bytes)
      try
        let pid = r.u32_be()?
        let secret = r.u32_be()?
        conn.log()(Fine) and conn.log().log("backend: key data, pid " + pid.string())
        // stash pid/secret if you'll support CancelRequest later
      else
        conn.log()(Warn) and conn.log().log("backend: malformed BackendKeyData body")
      end
      BarnyardClientAwaitParameterStatus
    | 'Z' =>                          // ReadyForQuery: 1 status byte
      conn.log()(Fine) and conn.log().log("backend: handshake complete")
      BarnyardClientIdle   // offer to the pool, await assignment
    | 'E' =>                          // ErrorResponse — backend rejected something
      conn.log()(Error) and conn.log().log("backend: ErrorResponse during startup")
      BarnyardConnectionHardClose
    else
      conn.log()(Error) and conn.log().log("backend: unexpected startup message " + Char(_msg_type))
      BarnyardConnectionHardClose
    end
