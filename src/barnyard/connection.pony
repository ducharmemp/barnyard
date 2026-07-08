use "buffered"
use "collections"
use "logger"
use "lori"

interface _BarnyardConnection
  fun ref log(): Logger[String]
  fun ref send(payload: (ByteSeq | ByteSeqIter))
  fun ref buffer_until(qty: (BufferSize | Streaming))
  fun ref mute()
  fun ref unmute()
  fun ref hard_close()
  fun ref close()
  fun ref params(): Map[String, String]
  fun ref on_startup_complete()
  fun ref acquire_backend()
  fun ref release_backend()
  fun ref has_backend(): Bool
  fun ref pipe_send(data: (ByteSeq | ByteSeqIter))
  fun ref stage(data: ByteSeq val)
  fun ref flush_pipe()
  be pipe_receive(data: (ByteSeq | ByteSeqIter))

interface _BarnyardConnectionReaderState
  fun read(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box
  fun pump(conn: _BarnyardConnection ref, data: ByteSeq val): _BarnyardConnectionState box => this
  fun pump_many(conn: _BarnyardConnection ref, data: ByteSeqIter): _BarnyardConnectionState box =>
    """
    Pump a multi-buffer message through the state machine one buffer at a
    time. States that just relay (e.g. the piped backend) override this to
    forward the whole sequence in a single writev.
    """
    var state: _BarnyardConnectionState box = this
    for b in data.values() do
      match state
      | let rs: _BarnyardConnectionReaderState box => state = rs.pump(conn, b)
      end
    end
    state
  fun resume(conn: _BarnyardConnection ref): _BarnyardConnectionState box => this

interface _BarnyardConnectionWriterState
  fun write(conn: _BarnyardConnection ref): _BarnyardConnectionState box

type _BarnyardConnectionState is (_BarnyardConnectionReaderState | _BarnyardConnectionWriterState)

primitive _Arm
  fun apply(conn: _BarnyardConnection ref, qty: USize) =>
    match MakeBufferSize(qty)
    | let b: BufferSize => conn.buffer_until(b)
    end

primitive _MaxArm
  """
  The largest buffer_until lori accepts (its read buffer minimum, 16384 by
  default). Frame bodies larger than this are read in pieces this big.
  """
  fun apply(): USize => 16384

primitive _FrameHeader
  """
  Parses a postgres frame header: a type byte followed by a big-endian u32
  length that counts itself but not the type byte. Returns the type and
  body length, or None when the header is truncated or the length is
  malformed.
  """
  fun parse(data: ByteSeq val): ((U8, USize) | None) =>
    try
      let r = Reader
      r.append(data)
      let msg_type = r.u8()?
      let len = r.u32_be()?.usize()
      if len < 4 then return None end
      (msg_type, len - 4)
    else
      None
    end

primitive _ArmForMute
  """
  Arm the maximum buffer size before muting a connection that may have
  unconsumed data buffered. lori's read loop runs its buffer-resize check
  and one more receive() in the same pass as a mute taken mid-delivery; if
  buffered bytes exceed the armed size the buffer isn't grown, and a full
  buffer makes that receive() a 0-byte read, which lori treats as
  peer-close. Arming the maximum makes the grow check always pass. Every
  unmute path re-arms its real frame size before the read loop resumes, so
  this never affects delivery. (Root cause is a lori issue: it should
  re-check mute, and never receive() into zero free space.)
  """
  fun apply(conn: _BarnyardConnection ref) =>
    _Arm(conn, _MaxArm())

class _BarnyardBackendInfo
  let host: String
  let port: String
  let username: String
  let password: String
  let database: String

  new create(host': String, port': String, username': String, password': String, database': String) =>
    host = host'
    port = port'
    username = username'
    password = password'
    database = database'

class _BarnyardServerInfo
  let host: String
  let port: String

  new create(host': String, port': String) =>
    host = host'
    port = port'
