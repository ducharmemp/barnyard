use "collections"
use "lori"

interface _PoolWaitable
  be on_backend_acquired(backend: _StableClientConnection)

actor _StableConnectionPooler
  embed _idle: Array[_StableClientConnection tag] = _idle.create()
  embed _waiters: List[_PoolWaitable tag] = _waiters.create()
  var _auth: TCPConnectAuth
  var _host: String
  var _port: String
  var _username: String
  var _password: String
  var _pool_size: U32
  var _total_pool_size: U32 = 0
  var _out: OutStream

  new create(auth: TCPConnectAuth, host: String, port: String, username: String, password: String, pool_size: U32, out: OutStream) =>
    _auth = auth
    _host = host
    _port = port
    _username = username
    _password = password
    _pool_size = pool_size
    _out = out

  be acquire(client: _PoolWaitable tag) =>
    try
      let backend = _idle.pop()?
      client.on_backend_acquired(backend)
    else
      if _total_pool_size < _pool_size then
        _spawn_connection(client)
      else
        _waiters.push(client)
      end
    end

  be release(backend: _StableClientConnection tag) =>
    try
      let waiter = _waiters.shift()?
      waiter.on_backend_acquired(backend)
    else
      _idle.push(backend)
    end

  fun ref _spawn_connection(client: _PoolWaitable tag) =>
    _total_pool_size = _total_pool_size + 1

