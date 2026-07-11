use "connection"
use "logger"
use "lori"

primitive Barnyard
  fun apply(env: Env) =>
    // Info: one-shot lifecycle messages only. Flip to Fine to trace
    // per-connection and per-query activity.
    let log = StringLogger(Info, env.out)

    var port: String = "7669"
    var pool_size: USize = 64
    var read_buffer_bytes: USize = 16384
    let port_key = "BARNYARD_PORT="
    let pool_key = "BARNYARD_POOL="
    let read_buffer_key = "BARNYARD_READ_BUFFER="
    for v in env.vars.values() do
      if v.at(port_key) then
        port = v.substring(port_key.size().isize())
      elseif v.at(pool_key) then
        pool_size = try v.substring(pool_key.size().isize()).usize()? else pool_size end
      elseif v.at(read_buffer_key) then
        read_buffer_bytes =
          try v.substring(read_buffer_key.size().isize()).usize()? else read_buffer_bytes end
      end
    end

    let read_buffer_size = BarnyardReadBufferSize(read_buffer_bytes)

    let work_queue: BarnyardWorkQueue = BarnyardWorkQueue
    let pool = BarnyardConnectionPooler(
      TCPConnectAuth(env.root),
      recover val BarnyardBackendInfo("", "5432", "postgres", "postgres", "postgres") end,
      work_queue,
      pool_size,
      read_buffer_size,
      log
    )
    BarnyardServer(TCPListenAuth(env.root), recover val BarnyardServerInfo("", port) end, work_queue, read_buffer_size, log)
