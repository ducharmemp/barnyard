use "collections"
use "lori"

interface _StableConnection
  fun ref send(payload: (ByteSeq | ByteSeqIter))
  fun ref buffer_until(qty: BufferSize)
  fun ref hard_close()
  fun ref close()
  fun ref params(): Map[String, String]
  fun ref on_startup_complete()
    

interface _StableConnectionReaderState
  fun read(conn: _StableConnection ref, data: Array[U8] iso): _StableConnectionState box

interface _StableConnectionWriterState
  fun write(conn: _StableConnection ref): _StableConnectionState box

type _StableConnectionState is (_StableConnectionReaderState | _StableConnectionWriterState)

primitive _Arm
  fun apply(conn: _StableConnection ref, qty: USize) =>
    match MakeBufferSize(qty)
    | let b: BufferSize => conn.buffer_until(b)
    end

interface _StableConnectionNotifier
  fun ref startup_complete() => None

primitive _NoopStableConnectionNotifier is _StableConnectionNotifier

class _StableBackendInfo
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

class _StableServerInfo
  let host: String
  let port: String

  new create(host': String, port': String) =>
    host = host'
    port = port'

