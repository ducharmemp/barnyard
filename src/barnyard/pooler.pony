use "collections"
use "logger"
use "lori"
use "itertools"

interface _PoolWaitable
  be on_backend_acquired(backend: _BarnyardClientConnection)

actor _BarnyardConnectionPooler
  embed _idle: Array[_BarnyardClientConnection tag] = _idle.create()
  embed _waiters: List[_PoolWaitable tag] = _waiters.create()
  var _auth: TCPConnectAuth
  var _backend_info: _BarnyardBackendInfo val
  var _pool_size: USize
  var _current_pool_size: USize = 0
  let _log: Logger[String]

  new create(auth: TCPConnectAuth, backend_info: _BarnyardBackendInfo val, pool_size: USize, log: Logger[String]) =>
    _auth = auth
    _backend_info = backend_info
    _pool_size = pool_size
    _log = log

    for _ in Iter[USize](Range(0, pool_size)) do
      _spawn_connection()
    end

  be acquire(client: _PoolWaitable tag) =>
    try
      let backend = _idle.pop()?
      client.on_backend_acquired(backend)
    else
      // Always queue the client — a freshly spawned backend releases itself
      // into the pool once its startup completes, which serves the queue.
      _waiters.push(client)
      if _current_pool_size < _pool_size then
        _spawn_connection()
      end
    end

  be release(backend: _BarnyardClientConnection tag) =>
    try
      let waiter = _waiters.shift()?
      waiter.on_backend_acquired(backend)
    else
      _idle.push(backend)
    end

  be retire(backend: _BarnyardClientConnection tag) =>
    """
    A backend connection died. Drop it from pool accounting so the pool
    doesn't drain permanently. Respawn only when clients are waiting —
    respawning unconditionally would hot-loop while the database is down.
    """
    _current_pool_size = _current_pool_size - 1
    try _idle.delete(_idle.find(backend)?)? end
    if (_waiters.size() > 0) and (_current_pool_size < _pool_size) then
      _spawn_connection()
    end

  fun ref _spawn_connection() =>
    _current_pool_size = _current_pool_size + 1
    _BarnyardClientConnection(_auth, _backend_info, this, _log).start()
