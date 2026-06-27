use "lori"

primitive Stable
  fun apply(env: Env) =>
    let pool = _StableConnectionPooler(TCPConnectAuth(env.root), "", "5432", "postgres", "postgres", 5, env.out)
    _StableClientConnection(TCPConnectAuth(env.root), recover val _StableBackendInfo("", "5432", "postgres", "postgres", "postgres") end, env.out)
    StableServer(TCPListenAuth(env.root), recover val _StableServerInfo("", "7669") end, env.out)
