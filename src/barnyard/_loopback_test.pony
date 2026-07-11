use "connection"
use "harness"
use "logger"
use "lori"
use "pony_test"
use "promises"

actor \nodoc\ _LoopbackListener is TCPListenerActor
  var _tcp_listener: TCPListener = TCPListener.none()
  let _h: TestHelper
  let _server_auth: TCPServerAuth
  let _work_queue: BarnyardWorkQueue
  let _log: Logger[String]
  let _server_info: BarnyardServerInfo val
  let _on_ready: {()} val
  embed _conns: Array[BarnyardServerConnection tag] = _conns.create()

  new create(h: TestHelper, auth: TCPListenAuth, info: BarnyardServerInfo val,
    ex: BarnyardWorkQueue, on_ready: {()} val)
  =>
    _h = h
    _server_auth = TCPServerAuth(auth)
    _work_queue = ex
    _log = StringLogger(Error, h.env.out)
    _server_info = info
    _on_ready = on_ready
    _tcp_listener = TCPListener(auth, info.host, info.port, this)

  fun ref _listener(): TCPListener => _tcp_listener

  fun ref _on_accept(fd: U32): BarnyardServerConnection =>
    let c = BarnyardServerConnection(_server_auth, fd, _server_info, _work_queue, BarnyardReadBufferSize(16384), _log)
    _conns.push(c)
    c

  fun ref _on_listening() => _on_ready()

  fun ref _on_listen_failure() => _h.fail("loopback listener failed to bind")

  fun ref _on_closed() =>
    for c in _conns.values() do c.dispose() end

actor \nodoc\ _RawHandshakeClient is (TCPConnectionActor & ClientLifecycleEventReceiver)
  var _tcp: TCPConnection = TCPConnection.none()
  let _h: TestHelper
  embed _buf: Array[U8] = _buf.create()
  var _declined: Bool = false

  new create(h: TestHelper, auth: TCPConnectAuth, host: String, port: String) =>
    _h = h
    _tcp = TCPConnection.client(auth, host, port, "", this, this)

  fun ref _connection(): TCPConnection => _tcp

  fun ref _on_connected() =>
    _tcp.send(SslRequest())

  fun ref _on_received(data: Array[U8] iso): ReadAction =>
    _buf.append(consume data)
    if not _declined then
      try _h.assert_eq[U8]('N', _buf(0)?, "decline byte") end
      _h.assert_eq[USize](1, _buf.size(), "exactly one decline byte")
      _buf.clear()
      _declined = true
      _tcp.send(StartupLiteral())
      return KeepReading
    end
    _walk()
    KeepReading

  fun ref _walk() =>
    let frames = SplitFrames(ToVal(_buf))
    try
      (let last_type: U8, let last_body: Array[U8] val) =
        frames(frames.size() - 1)?
      if last_type != 'Z' then return end
      (let t0: U8, let b0: Array[U8] val) = frames(0)?
      _h.assert_eq[U8]('R', t0, "first frame is auth")
      EqBytes(_h, recover val [as U8: 0; 0; 0; 0] end, b0, "auth code")
      var s_count: USize = 0
      var k_count: USize = 0
      var i: USize = 1
      while i < (frames.size() - 1) do
        (let t: U8, let b: Array[U8] val) = frames(i)?
        if t == 'S' then s_count = s_count + 1 end
        if t == 'K' then
          k_count = k_count + 1
          _h.assert_eq[USize](8, b.size(), "key data body")
        end
        i = i + 1
      end
      _h.assert_true(s_count >= 1, "parameter status frames")
      _h.assert_eq[USize](1, k_count, "one key data frame")
      EqBytes(_h, recover val [as U8: 'I'] end, last_body, "rfq status")
      _h.complete_action("handshake")
    end

  fun ref _on_connection_failure(reason: ConnectionFailureReason) =>
    _h.fail("raw handshake client failed to connect")

  fun ref _on_closed() => None

actor \nodoc\ _RawBigQueryClient is (TCPConnectionActor & ClientLifecycleEventReceiver)
  var _tcp: TCPConnection = TCPConnection.none()
  let _h: TestHelper
  let _query: Array[U8] val
  embed _buf: Array[U8] = _buf.create()
  var _sent_query: Bool = false

  new create(h: TestHelper, auth: TCPConnectAuth, host: String, port: String,
    query: Array[U8] val)
  =>
    _h = h
    _query = query
    _tcp = TCPConnection.client(auth, host, port, "", this, this)

  fun ref _connection(): TCPConnection => _tcp

  fun ref _on_connected() =>
    _tcp.send(StartupLiteral())

  fun ref _on_received(data: Array[U8] iso): ReadAction =>
    if _sent_query then return KeepReading end
    _buf.append(consume data)
    let frames = SplitFrames(ToVal(_buf))
    try
      (let t: U8, _) = frames(frames.size() - 1)?
      if t == 'Z' then
        _sent_query = true
        _tcp.send(_query)
      end
    end
    KeepReading

  fun ref _on_connection_failure(reason: ConnectionFailureReason) =>
    _h.fail("raw big-query client failed to connect")

  fun ref _on_closed() => None

actor \nodoc\ _RawGarbageClient is (TCPConnectionActor & ClientLifecycleEventReceiver)
  var _tcp: TCPConnection = TCPConnection.none()
  let _h: TestHelper
  var _got: USize = 0

  new create(h: TestHelper, auth: TCPConnectAuth, host: String, port: String) =>
    _h = h
    _tcp = TCPConnection.client(auth, host, port, "", this, this)

  fun ref _connection(): TCPConnection => _tcp

  fun ref _on_connected() =>
    _tcp.send(recover val [as U8: 0; 0; 0; 3] end)

  fun ref _on_received(data: Array[U8] iso): ReadAction =>
    _got = _got + data.size()
    KeepReading

  fun ref _on_connection_failure(reason: ConnectionFailureReason) =>
    _h.fail("raw garbage client failed to connect")

  fun ref _on_closed() =>
    _h.assert_eq[USize](0, _got, "no bytes before close")
    _h.complete_action("closed")

class \nodoc\ iso _LoopbackHandshake is UnitTest
  fun name(): String => "integration/loopback_startup_parity"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    h.expect_action("paired")
    let ex = BarnyardWorkQueue
    let probe = ProbePeer(h)
    probe.expect_any_peer("paired")
    ex.push(probe)   // probe stands in for a server with work; a real backend pops it
    let log = StringLogger(Error, h.env.out)
    let auth = h.env.root
    let binfo = recover val
      BarnyardBackendInfo("127.0.0.1", "17701", "loop", "pw", "loopdb")
    end
    let pool = BarnyardConnectionPooler(TCPConnectAuth(auth), binfo, ex, 0, BarnyardReadBufferSize(16384), log)
    let client = BarnyardClientConnection(TCPConnectAuth(auth), binfo, ex, pool, BarnyardReadBufferSize(16384), log)
    h.dispose_when_done(client)
    let sinfo = recover val BarnyardServerInfo("127.0.0.1", "17701") end
    let listener = _LoopbackListener(h, TCPListenAuth(auth), sinfo, ex,
      {() => client.start()})
    h.dispose_when_done(listener)

class \nodoc\ iso _LoopbackRawHandshake is UnitTest
  fun name(): String => "integration/loopback_raw_handshake"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    h.expect_action("handshake")
    let ex = BarnyardWorkQueue
    let auth = h.env.root
    let sinfo = recover val BarnyardServerInfo("127.0.0.1", "17702") end
    let listener = _LoopbackListener(h, TCPListenAuth(auth), sinfo, ex,
      {() =>
        h.dispose_when_done(
          _RawHandshakeClient(h, TCPConnectAuth(auth), "127.0.0.1", "17702"))
      })
    h.dispose_when_done(listener)

class \nodoc\ iso _LoopbackLargeQuery is UnitTest
  fun name(): String => "integration/loopback_large_query_relay"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    h.expect_action("large-relayed")
    let ex = BarnyardWorkQueue
    let probe = ProbePeer(h)
    let qframe = Frame('Q', recover val Array[U8].init('q', 40000) end)
    probe.expect_forwarded(qframe, "large-relayed")
    probe.inviting()   // acts as a backend: invites the server it's matched with
    let bp = Promise[BarnyardConnection tag]
    bp.next[None]({(s: BarnyardConnection tag)(probe) => probe.peer_with(s) })
    ex.pop(bp)   // probe stands in for a free backend popping for work
    let auth = h.env.root
    let sinfo = recover val BarnyardServerInfo("127.0.0.1", "17704") end
    let listener = _LoopbackListener(h, TCPListenAuth(auth), sinfo, ex,
      {() =>
        h.dispose_when_done(
          _RawBigQueryClient(h, TCPConnectAuth(auth), "127.0.0.1", "17704", qframe))
      })
    h.dispose_when_done(listener)

class \nodoc\ iso _LoopbackGarbageStartup is UnitTest
  fun name(): String => "integration/loopback_garbage_startup_closes"

  fun apply(h: TestHelper) =>
    h.long_test(5_000_000_000)
    h.expect_action("closed")
    let ex = BarnyardWorkQueue
    let auth = h.env.root
    let sinfo = recover val BarnyardServerInfo("127.0.0.1", "17703") end
    let listener = _LoopbackListener(h, TCPListenAuth(auth), sinfo, ex,
      {() =>
        h.dispose_when_done(
          _RawGarbageClient(h, TCPConnectAuth(auth), "127.0.0.1", "17703"))
      })
    h.dispose_when_done(listener)
