use "lori"
use "constrained_types"

primitive Arm
  fun apply(conn: BarnyardConnection ref, qty: USize) =>
    match MakeBufferSize(qty)
    | let b: BufferSize => conn.buffer_until(b)
    end

primitive ArmStream
  fun apply(conn: BarnyardConnection ref) =>
    conn.buffer_until(Streaming)

primitive ArmMax
  fun apply(conn: BarnyardConnection ref, value: USize = 1024 * 16) =>
    Arm(conn, value.min(1024 * 32))

primitive BarnyardReadBufferSize
  fun apply(bytes: USize): ReadBufferSize =>
    match MakeReadBufferSize(bytes)
    | let r: ReadBufferSize => r
    | let _: ValidationFailure => DefaultReadBufferSize()
    end
