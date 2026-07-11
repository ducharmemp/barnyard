use "connection"
use "collections"
use "logger"
use "lori"
use "itertools"

actor BarnyardConnectionPooler
  var _auth: TCPConnectAuth
  var _backend_info: BarnyardBackendInfo val
  var _work_queue: BarnyardWorkQueue
  var _pool_size: USize
  var _current_pool_size: USize = 0
  let _read_buffer_size: ReadBufferSize
  let _log: Logger[String]

  new create(auth: TCPConnectAuth, backend_info: BarnyardBackendInfo val, work_queue: BarnyardWorkQueue, pool_size: USize, read_buffer_size: ReadBufferSize, log: Logger[String]) =>
    _auth = auth
    _backend_info = backend_info
    _work_queue = work_queue
    _pool_size = pool_size
    _read_buffer_size = read_buffer_size
    _log = log

    for _ in Iter[USize](Range(0, pool_size)) do
      _spawn_connection()
    end

  be retire(backend: BarnyardClientConnection tag) =>
    // A backend's PG connection died; replace it to keep the pool full.
    _current_pool_size = _current_pool_size - 1
    if _current_pool_size < _pool_size then
      _spawn_connection()
    end

  fun ref _spawn_connection() =>
    _current_pool_size = _current_pool_size + 1
    BarnyardClientConnection(_auth, _backend_info, _work_queue, this, _read_buffer_size, _log).start()
