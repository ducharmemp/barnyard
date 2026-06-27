use "collections"
use "lori"
use "buffered"

actor _StableClientConnection is (TCPConnectionActor & ClientLifecycleEventReceiver & _StableConnection)
  var _tcp_connection: TCPConnection = TCPConnection.none()
  let _out: OutStream
  var _state: _StableConnectionState box
  let _params: Map[String, String] = _params.create()

  new create(auth: TCPConnectAuth, backend_info: _StableBackendInfo val, out: OutStream) =>
    _out = out
    _state = _StableClientStartup(backend_info, out)
    _tcp_connection = TCPConnection.client(auth, backend_info.host, backend_info.port, "", this, this)

  fun ref _connection(): TCPConnection =>
    _tcp_connection

  fun ref send(payload: (ByteSeq | ByteSeqIter)) =>
    match _connection().send(payload)
    | let e: SendError => _out.print("send failed"); hard_close()
    end

  fun ref buffer_until(qty: BufferSize) => _connection().buffer_until(qty)

  fun ref hard_close() =>
    _connection().hard_close()

  fun ref close() => _connection().close()

  fun ref params(): Map[String, String] => _params

  fun ref on_startup_complete() => None

  fun ref _on_connected() =>
    _out.print("Connected")
    _drain()

  fun ref _on_received(data: Array[U8] iso) =>
    match _state
    | let rs: _StableConnectionReaderState box => _state = rs.read(this, consume data)
    end
    _drain()

  fun ref _drain() =>
    var continue': Bool = true
    while continue' do
      match _state
      | let ws: _StableConnectionWriterState box => _state = ws.write(this)
      | let _: _StableConnectionReaderState box => continue' = false
      end
    end

  fun ref _on_closed() =>
    _out.print("Connection closed")
