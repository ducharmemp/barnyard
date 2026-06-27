 use "cli"
use "collections"
use "lori"
use "buffered"

actor StableServer is TCPListenerActor
  var _tcp_listener: TCPListener = TCPListener.none()
  let _out: OutStream
  let _server_auth: TCPServerAuth
  let _server_info: _StableServerInfo val

  new create(listen_auth: TCPListenAuth, server_info: _StableServerInfo val, out: OutStream) =>
    _out = out
    _server_auth = TCPServerAuth(listen_auth)
    _server_info = server_info
    _tcp_listener = TCPListener(listen_auth, _server_info.host, _server_info.port, this)

  fun ref _listener(): TCPListener => _tcp_listener
  fun ref _on_accept(fd: U32): _StableServerConnection =>
    _StableServerConnection(_server_auth, fd, _server_info, _out)

  fun ref _on_listening() =>
    _out.print("Echo server started")

  fun ref _on_listen_failure() =>
    _out.print("Couldn't start Echo server.")


actor _StableServerConnection is (TCPConnectionActor & ServerLifecycleEventReceiver & _StableConnection)
  var _tcp_connection: TCPConnection = TCPConnection.none()
  let _server_info: _StableServerInfo val
  let _out: OutStream
  var _state: _StableConnectionState box
  let _params: Map[String, String] = _params.create()
  var _startup_complete: Bool = false

  new create(auth: TCPServerAuth, fd: U32, server_info: _StableServerInfo val, out: OutStream) =>
    _out = out
    _server_info = server_info
    _state = _StableServerAwaitLength(out)
    _tcp_connection = TCPConnection.server(auth, fd, this, this)
    match MakeBufferSize(4)
    | let e: BufferSize => _tcp_connection.buffer_until(e)
    end

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

  fun ref on_startup_complete() =>
    if not _startup_complete then
      _startup_complete = true
    end

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

