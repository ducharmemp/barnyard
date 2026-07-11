use "connection"
use "lori"
use "logger"

actor BarnyardServer is TCPListenerActor
  var _tcp_listener: TCPListener = TCPListener.none()
  let _log: Logger[String]
  let _server_auth: TCPServerAuth
  let _server_info: BarnyardServerInfo val
  let _work_queue: BarnyardWorkQueue
  let _read_buffer_size: ReadBufferSize

  new create(listen_auth: TCPListenAuth, server_info: BarnyardServerInfo val, work_queue: BarnyardWorkQueue, read_buffer_size: ReadBufferSize, log: Logger[String]) =>
    _log = log
    _server_auth = TCPServerAuth(listen_auth)
    _server_info = server_info
    _work_queue = work_queue
    _read_buffer_size = read_buffer_size
    _tcp_listener = TCPListener(listen_auth, _server_info.host, _server_info.port, this)

  fun ref _listener(): TCPListener => _tcp_listener
  fun ref _on_accept(fd: U32): BarnyardServerConnection =>
    BarnyardServerConnection(_server_auth, fd, _server_info, _work_queue, _read_buffer_size, _log)

  fun ref _on_listening() =>
    _log(Info) and _log.log("Barnyard listening on port " + _server_info.port)

  fun ref _on_listen_failure() =>
    _log(Error) and _log.log("Couldn't start Barnyard; is port " + _server_info.port + " in use?")
