use "connection"
use "client"
use "logger"
use "lori"
use "promises"

actor BarnyardClientConnection is (TCPConnectionActor & ClientLifecycleEventReceiver & BarnyardConnection)
  var _tcp_connection: TCPConnection = TCPConnection.none()
  let _auth: TCPConnectAuth
  let _backend_info: BarnyardBackendInfo val
  let _log: Logger[String]
  var _state: BarnyardConnectionInteractableState box
  let _work_queue: BarnyardWorkQueue
  let _pool: BarnyardConnectionPooler
  let _read_buffer_size: ReadBufferSize
  var _retired: Bool = false

  new create(auth: TCPConnectAuth, backend_info: BarnyardBackendInfo val, work_queue: BarnyardWorkQueue, pool: BarnyardConnectionPooler, read_buffer_size: ReadBufferSize, log': Logger[String]) =>
    _log = log'
    _backend_info = backend_info
    _state = BarnyardClientStartup(_backend_info)
    _work_queue = work_queue
    _pool = pool
    _read_buffer_size = read_buffer_size
    _auth = auth

  be start() =>
    _tcp_connection = TCPConnection.client(_auth, _backend_info.host, _backend_info.port, "", this, this, _read_buffer_size)

  fun ref _connection(): TCPConnection =>
    _tcp_connection

  fun ref log(): Logger[String] => _log

  fun ref send(payload: (ByteSeq | ByteSeqIter)) =>
    match _connection().send(payload)
    | let e: SendError =>
      _log(Error) and _log.log("backend: send failed, retiring")
      _retire()
    end

  fun ref buffer_until(qty: (BufferSize | Streaming)) => _connection().buffer_until(qty)

  fun ref mute() => _connection().mute()
  fun ref unmute() => _connection().unmute()

  fun ref on_param(key: String val, value: String val) => None

  fun ref established() =>
    _log(Fine) and _log.log("backend: established, popping for work")
    let p = Promise[BarnyardConnection tag]
    let self: BarnyardConnection tag = this
    _work_queue.pop(p)
    p.next[None]({(s: BarnyardConnection tag) => self.peer_with(s) })

  be peer_with(peer: BarnyardConnection tag) =>
    match _state
    | let is': BarnyardConnectionIdleState box =>
      _log(Fine) and _log.log("backend: peered with a client")
      _thunk(is'.wake(this, peer))
    else
      _log(Warn) and _log.log("backend: peer_with ignored in state " + _state.name())
    end

  be forward(data: ForwardData) =>
    match _state
    | let pipe: BarnyardConnectionPipingState box => _thunk(pipe.pipe(this, data))
    else
      _log(Warn) and _log.log("backend: forward ignored in state " + _state.name())
    end

  be release() =>
    // Our server (client) disconnected. Return to the pool.
    // FIXME: if this fires mid-transaction the PG session is left dirty
    _log(Fine) and _log.log("backend: client gone, returning to pool")
    _thunk(BarnyardClientIdle)

  fun ref _on_connected() =>
    _tcp_connection.set_nodelay(true)
    _log(Fine) and _log.log("backend: connected")
    _thunk(_state)

  fun ref _on_received(data: Array[U8] iso): ReadAction =>
    let bytes: Array[U8] val = consume data
    match _state
    | let rs: BarnyardConnectionReaderState box => _thunk(rs.read(this, bytes))
    else
      _log(Warn) and _log.log("backend: " + bytes.size().string() + " bytes ignored in state " + _state.name())
    end
    KeepReading

  fun ref _thunk(state: BarnyardConnectionTransition box) =>
    var continue': Bool = true
    var from: String = _state.name()
    var state' = state
    while continue' do
      _log(Fine) and _log.log("backend: " + from + " -> " + state'.name())
      from = state'.name()
      match \exhaustive\ state'
      | let _: BarnyardConnectionClose box =>
          continue' = false
          _connection().close()
      | let _: BarnyardConnectionHardClose box =>
          continue' = false
          _connection().hard_close()
      | let ws: BarnyardConnectionWriterState box =>
          state' = ws.write(this)
      | let is': BarnyardConnectionIdleState box =>
          continue' = false
          _state = is'
          is'.enter(this)
      | let pipe: BarnyardConnectionPipingState box =>
          continue' = false
          _state = pipe
          pipe.enter(this)
      | let rs: BarnyardConnectionReaderState box =>
          continue' = false
          _state = rs
          rs.enter(this)
      end
    end

  fun ref _on_closed() =>
    _log(Fine) and _log.log("backend: connection closed")
    _retire()

  fun ref _on_connection_failure(reason: ConnectionFailureReason) =>
    _log(Warn) and _log.log("backend: connection failed")
    _retire()

  fun ref _retire() =>
    if not _retired then
      _retired = true
      _tcp_connection.hard_close()
      _pool.retire(this)
    end
