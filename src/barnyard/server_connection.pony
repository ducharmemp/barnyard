use "connection"
use "server"
use "logger"
use "lori"

actor BarnyardServerConnection is (TCPConnectionActor & ServerLifecycleEventReceiver & BarnyardConnection)
  let _log: Logger[String]
  let _work_queue: BarnyardWorkQueue
  let _server_info: BarnyardServerInfo val
  var _state: BarnyardConnectionInteractableState box
  var _tcp_connection: TCPConnection = TCPConnection.none()

  new create(auth: TCPServerAuth, fd: U32, server_info: BarnyardServerInfo val, work_queue: BarnyardWorkQueue, read_buffer_size: ReadBufferSize, log': Logger[String]) =>
    _log = log'
    _server_info = server_info
    _state = BarnyardServerAwaitLength
    _work_queue = work_queue
    _tcp_connection = TCPConnection.server(auth, fd, this, this, read_buffer_size)
    match MakeBufferSize(4)
    | let e: BufferSize => _tcp_connection.buffer_until(e)
    end

  fun ref _on_started() =>
    _tcp_connection.set_nodelay(true)

  fun ref _connection(): TCPConnection =>
    _tcp_connection

  fun ref log(): Logger[String] => _log

  fun ref send(payload: (ByteSeq | ByteSeqIter)) =>
    match _connection().send(payload)
    | let e: SendError =>
      _log(Error) and _log.log("client: send failed, closing")
      _tcp_connection.hard_close()
    end

  fun ref buffer_until(qty: (BufferSize | Streaming)) => _connection().buffer_until(qty)

  fun ref mute() => _connection().mute()
  fun ref unmute() => _connection().unmute()

  fun ref close() => _connection().close()

  fun ref on_param(key: String val, value: String val) => None

  fun ref established() =>
    _log(Fine) and _log.log("client: pushing work")
    _work_queue.push(this)

  be peer_with(peer: BarnyardConnection tag) =>
    match _state
    | let is': BarnyardConnectionIdleState box =>
      _log(Fine) and _log.log("client: bound to a backend")
      _thunk(is'.wake(this, peer))
    else
      _log(Warn) and _log.log("client: peer_with ignored in state " + _state.name())
    end

  be forward(data: ForwardData) =>
    match _state
    | let pipe: BarnyardConnectionPipingState box => _thunk(pipe.pipe(this, data))
    else
      _log(Warn) and _log.log("client: forward ignored in state " + _state.name())
    end

  be release() =>
    match _state
    | let _: BarnyardServerBound box =>
      _log(Fine) and _log.log("client: unbound by backend")
      _thunk(BarnyardServerUnbound)
    else
      _log(Warn) and _log.log("client: release ignored in state " + _state.name())
    end

  fun ref _on_received(data: Array[U8] iso): ReadAction =>
    let bytes: Array[U8] val = consume data
    match _state
    | let rs: BarnyardConnectionReaderState box => _thunk(rs.read(this, bytes))
    else
      _log(Warn) and _log.log("client: " + bytes.size().string() + " bytes ignored in state " + _state.name())
    end
    KeepReading

  fun ref _thunk(state: BarnyardConnectionTransition box) =>
    var continue': Bool = true
    var from: String = _state.name()
    var state' = state
    while continue' do
      _log(Fine) and _log.log("client: " + from + " -> " + state'.name())
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
    _log(Fine) and _log.log("client: connection closed")
    // withdraw ourselves if still parked as work; if bound, hand the backend back
    _work_queue.withdraw(this)
    match _state
    | let p: BarnyardConnectionPipingState box => p.closed(this)
    end

