use "logger"
use "lori"

primitive Stable
  fun apply(env: Env) =>
    // Info: one-shot lifecycle messages only. Flip to Fine to trace
    // per-connection and per-query activity.
    let log = StringLogger(Info, env.out)

    var port: String = "7669"
    var pool_size: USize = 64
    let port_key = "STABLE_PORT="
    let pool_key = "STABLE_POOL="
    for v in env.vars.values() do
      if v.at(port_key) then
        port = v.substring(port_key.size().isize())
      elseif v.at(pool_key) then
        pool_size = try v.substring(pool_key.size().isize()).usize()? else pool_size end
      end
    end

    let pool = _StableConnectionPooler(TCPConnectAuth(env.root), recover val _StableBackendInfo("", "5432", "postgres", "postgres", "postgres") end, pool_size, log)
    StableServer(TCPListenAuth(env.root), recover val _StableServerInfo("", port) end, pool, log)
