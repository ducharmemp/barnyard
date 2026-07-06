use "logger"
use "lori"

primitive Barnyard
  fun apply(env: Env) =>
    // Info: one-shot lifecycle messages only. Flip to Fine to trace
    // per-connection and per-query activity.
    let log = StringLogger(Info, env.out)

    var port: String = "7669"
    var pool_size: USize = 64
    let port_key = "BARNYARD_PORT="
    let pool_key = "BARNYARD_POOL="
    for v in env.vars.values() do
      if v.at(port_key) then
        port = v.substring(port_key.size().isize())
      elseif v.at(pool_key) then
        pool_size = try v.substring(pool_key.size().isize()).usize()? else pool_size end
      end
    end

    let pool = _BarnyardConnectionPooler(TCPConnectAuth(env.root), recover val _BarnyardBackendInfo("", "5432", "postgres", "postgres", "postgres") end, pool_size, log)
    BarnyardServer(TCPListenAuth(env.root), recover val _BarnyardServerInfo("", port) end, pool, log)
