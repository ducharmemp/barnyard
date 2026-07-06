use "collections"
use "logger"
use "lori"

actor BarnyardServer is TCPListenerActor
  var _tcp_listener: TCPListener = TCPListener.none()
  let _log: Logger[String]
  let _server_auth: TCPServerAuth
  let _server_info: _BarnyardServerInfo val
  let _pool: _BarnyardConnectionPooler

  new create(listen_auth: TCPListenAuth, server_info: _BarnyardServerInfo val, pool: _BarnyardConnectionPooler, log: Logger[String]) =>
    _log = log
    _server_auth = TCPServerAuth(listen_auth)
    _server_info = server_info
    _pool = pool
    _tcp_listener = TCPListener(listen_auth, _server_info.host, _server_info.port, this)

  fun ref _listener(): TCPListener => _tcp_listener
  fun ref _on_accept(fd: U32): _BarnyardServerConnection =>
    _BarnyardServerConnection(_server_auth, fd, _server_info, _pool, _log)

  fun ref _on_listening() =>
    _log(Info) and _log.log("Barnyard listening on port " + _server_info.port)

  fun ref _on_listen_failure() =>
    _log(Error) and _log.log("Couldn't start Barnyard; is port " + _server_info.port + " in use?")

actor _BarnyardServerConnection is (TCPConnectionActor & ServerLifecycleEventReceiver & _BarnyardConnection & _PoolWaitable)
  var _tcp_connection: TCPConnection = TCPConnection.none()
  let _server_info: _BarnyardServerInfo val
  let _log: Logger[String]
  var _state: _BarnyardConnectionState box
  let _params: Map[String, String] = _params.create()
  var _startup_complete: Bool = false
  let _pool: _BarnyardConnectionPooler
  var _peer: (_BarnyardClientConnection | None) = None
  var _staged: Array[ByteSeq] iso = recover iso Array[ByteSeq] end
  var _staged_bytes: USize = 0

  new create(auth: TCPServerAuth, fd: U32, server_info: _BarnyardServerInfo val, pool: _BarnyardConnectionPooler, log': Logger[String]) =>
    _log = log'
    _server_info = server_info
    _state = _BarnyardServerAwaitLength
    _pool = pool
    _tcp_connection = TCPConnection.server(auth, fd, this, this)
    match MakeBufferSize(4)
    | let e: BufferSize => _tcp_connection.buffer_until(e)
    end

  fun ref _on_started() =>
    // Socket options dispatch through the connection state machine and are
    // silently rejected before the connection is _Open, so nodelay can't be
    // set from the constructor.
    _tcp_connection.set_nodelay(true)

  fun ref _connection(): TCPConnection =>
    _tcp_connection

  fun ref log(): Logger[String] => _log

  fun ref send(payload: (ByteSeq | ByteSeqIter)) =>
    match _connection().send(payload)
    | let e: SendError =>
      _log(Error) and _log.log("send to client failed")
      hard_close()
    end

  fun ref buffer_until(qty: (BufferSize | Streaming)) => _connection().buffer_until(qty)

  fun ref mute() => _connection().mute()
  fun ref unmute() => _connection().unmute()

  fun ref hard_close() =>
    _connection().hard_close()

  fun ref close() => _connection().close()

  fun ref params(): Map[String, String] => _params

  fun ref pipe_send(data: (ByteSeq | ByteSeqIter)) =>
    match _peer
    | let p: _BarnyardClientConnection => p.pipe_receive(data)
    end

  fun ref stage(data: ByteSeq val) =>
    """
    Queue a chunk of frontend bytes for the backend. Chunks accumulate until
    flush_pipe() so a whole client batch (e.g. Parse/Bind/Describe/Execute/
    Sync) reaches the backend as one writev. Auto-flushes when the staged
    bytes get large so oversized bodies and COPY streams stay bounded.
    """
    _staged.push(data)
    _staged_bytes = _staged_bytes + data.size()
    if _staged_bytes >= 32768 then
      flush_pipe()
    end

  fun ref flush_pipe() =>
    // No peer means the pool acquire is still in flight; the batch-end
    // flush always runs after pairing, so keep accumulating until then.
    if (_staged_bytes > 0) and (_peer isnt None) then
      let batch: Array[ByteSeq] iso = _staged = recover iso Array[ByteSeq] end
      _staged_bytes = 0
      pipe_send(consume batch)
    end

  be pipe_receive(data: (ByteSeq | ByteSeqIter)) =>
    match _state
    | let rs: _BarnyardConnectionReaderState box =>
      _state = match data
      | let b: ByteSeq => rs.pump(this, b)
      | let bs: ByteSeqIter => rs.pump_many(this, bs)
      end
    end

  fun ref on_startup_complete() =>
    if not _startup_complete then
      _startup_complete = true
    end

  fun ref has_backend(): Bool => _peer isnt None

  fun ref acquire_backend() =>
    match _peer
    | let p: _BarnyardClientConnection =>
      // A transaction is in progress (the last ReadyForQuery wasn't idle),
      // so the lease is sticky: route the next statement to the held
      // backend. Behavior call to self so the reader state has settled to
      // _BarnyardServerAwaitBackend before it's handled.
      on_backend_acquired(p)
    | None =>
      _pool.acquire(this)
    end

  fun ref release_backend() =>
    let old = _peer = None
    match old
    | let p: _BarnyardClientConnection =>
      // unpair() is the single release point: the backend returns itself to
      // the pool.
      p.unpair()
    end

  be on_backend_acquired(backend: _BarnyardClientConnection) =>
    if not _tcp_connection.is_open() then
      // The psql client went away while we were waiting on the pool. Our
      // reader state is unchanged, so without this guard we'd pair the
      // backend to a dead connection and leak it from the pool.
      backend.unpair()
      return
    end
    match _state
    | let rs: _BarnyardConnectionReaderState box =>
      _peer = backend
      backend.pair(this)
      _state = rs.resume(this)
    else
      backend.unpair()
    end

  fun ref _on_received(data: Array[U8] iso) =>
    let bytes: Array[U8] val = consume data
    match _state
    | let rs: _BarnyardConnectionReaderState box => _state = rs.read(this, bytes)
    end
    _drain()

  fun ref _drain() =>
    var continue': Bool = true
    while continue' do
      match _state
      | let ws: _BarnyardConnectionWriterState box => _state = ws.write(this)
      | let _: _BarnyardConnectionReaderState box => continue' = false
      end
    end

  fun ref _on_closed() =>
    let old = _peer = None
    match old
    | let p: _BarnyardClientConnection =>
      // A lease held at close time means a batch, copy, or transaction was
      // in flight — the backend's session state is unknown, so destroy it
      // rather than return it dirty. It retires itself from the pool, which
      // respawns on demand.
      p.dispose()
    end
    _log(Fine) and _log.log("client connection closed")
