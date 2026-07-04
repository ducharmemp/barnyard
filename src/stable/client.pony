use "collections"
use "logger"
use "lori"

actor _StableClientConnection is (TCPConnectionActor & ClientLifecycleEventReceiver & _StableConnection)
  """
  A pooled connection to the real Postgres backend.

  Owns its own pool membership: it releases itself to the pool when its
  startup handshake completes and whenever a borrower unpairs it, and it
  retires itself from the pool when its socket dies. Borrowers never talk to
  the pool about this connection — `unpair()` is the single release point,
  so a lease can't leak by a borrower forgetting one of several exit paths.
  """
  var _tcp_connection: TCPConnection = TCPConnection.none()
  let _auth: TCPConnectAuth
  let _backend_info: _StableBackendInfo val
  let _log: Logger[String]
  var _state: _StableConnectionState box
  let _pool: _StableConnectionPooler
  var _retired: Bool = false
  let _params: Map[String, String] = _params.create()
  var _peer: (_StableServerConnection | None) = None

  new create(auth: TCPConnectAuth, backend_info: _StableBackendInfo val, pool: _StableConnectionPooler, log': Logger[String]) =>
    _log = log'
    _backend_info = backend_info
    _state = _StableClientStartup(_backend_info)
    _pool = pool
    _auth = auth

  be start() =>
    _tcp_connection = TCPConnection.client(_auth, _backend_info.host, _backend_info.port, "", this, this)

  fun ref _connection(): TCPConnection =>
    _tcp_connection

  fun ref log(): Logger[String] => _log

  fun ref send(payload: (ByteSeq | ByteSeqIter)) =>
    match _connection().send(payload)
    | let e: SendError =>
      _log(Error) and _log.log("send to backend failed")
      hard_close()
    end

  fun ref buffer_until(qty: (BufferSize | Streaming)) => _connection().buffer_until(qty)

  fun ref mute() => _connection().mute()
  fun ref unmute() => _connection().unmute()

  fun ref hard_close() =>
    _connection().hard_close()

  fun ref close() => _connection().close()

  fun ref params(): Map[String, String] => _params

  fun ref on_startup_complete() =>
    _pool.release(this)

  fun ref acquire_backend() => None
  fun ref release_backend() => None
  fun ref has_backend(): Bool => _peer isnt None

  fun ref pipe_send(data: (ByteSeq | ByteSeqIter)) =>
    match _peer
    | let p: _StableServerConnection => p.pipe_receive(data)
    end

  // Staging is a frontend-side concern; the backend relays immediately.
  fun ref stage(data: ByteSeq val) => pipe_send(data)
  fun ref flush_pipe() => None

  be pipe_receive(data: (ByteSeq | ByteSeqIter)) =>
    match _state
    | let rs: _StableConnectionReaderState box =>
      _state = match data
      | let b: ByteSeq => rs.pump(this, b)
      | let bs: ByteSeqIter => rs.pump_many(this, bs)
      end
    end

  be pair(peer: _StableServerConnection) =>
    _peer = peer
    _state = _StableClientPiped.resume(this)

  be unpair() =>
    _peer = None
    _state = _StableClientAwaitQueryHeader.resume(this)
    if not _retired then
      _pool.release(this)
    end

  fun ref _on_connected() =>
    // Socket options dispatch through the connection state machine and are
    // silently rejected before the connection is _Open, so nodelay can't be
    // set from start().
    _tcp_connection.set_nodelay(true)
    _log(Fine) and _log.log("connected to backend")
    _drain()

  fun ref _on_received(data: Array[U8] iso) =>
    let bytes: Array[U8] val = consume data
    match _state
    | let rs: _StableConnectionReaderState box => _state = rs.read(this, bytes)
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
    _log(Fine) and _log.log("backend connection closed")
    _retire()

  fun ref _on_connection_failure(reason: ConnectionFailureReason) =>
    _log(Warn) and _log.log("backend connection failed")
    _retire()

  fun ref _retire() =>
    if not _retired then
      _retired = true
      _pool.retire(this)
    end
