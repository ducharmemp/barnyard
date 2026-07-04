use "pony_test"
use "lori"

class iso _LoopbackHandshake is UnitTest
  """
  Scaffold: bind a StableServer on loopback and point a _StableClientConnection
  at it. The two state machines should mate end-to-end through real sockets.

  This intentionally leaves the assertions to you. Hooks you can drive from:

    - implement a custom _PoolWaitable actor; pool.acquire(it); assert on
      on_backend_acquired firing within the long_test budget.
    - inject an OutStream that captures lines and assert on the log shape.
    - extend _StableConnection with a `notify` setter that fires on
      ReadyForQuery and assert that both sides reached it.

  Known wart: the client constructs its TCPConnection synchronously, so it
  races the listener's _on_listening. If you see ECONNREFUSED on first run,
  introduce a small delay or refactor the client to defer the connect until a
  start() behavior is invoked.
  """
  fun name(): String => "integration/loopback_handshake"

  fun apply(h: TestHelper) =>
    h.long_test(2_000_000_000)  // 2s budget; bump if needed

    let auth = h.env.root
    let host: String = "127.0.0.1"
    let port: String = "17669"


    //let pool = _StableConnectionPooler(
     // TCPConnectAuth(auth), host, port, "test", "test", 1, h.env.out)

    let server_info = _StableServerInfo(host, port)

    // StableServer(TCPListenAuth(auth), server_info, _LoopbackTestNotifier(h), h.env.out)

    //_StableClientConnection(
    // TCPConnectAuth(auth), pool, host, port,
    // "test", "test", "test", "", h.env.out)

