use "pony_test"
use "lori"

class iso _LoopbackHandshake is UnitTest
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

