use "buffered"

primitive _Pg
  fun ssl(): U32 => 80877103
  fun gss(): U32 => 80877104
  fun v3():  U32 => 196608

primitive _PgWire
  fun message(type_byte: U8, payload: Writer iso): Array[ByteSeq] val =>
    let payload_len = payload.size().u32()
    let bytes = payload.done()
    let w = Writer
    w.u8(type_byte)
    w.u32_be(payload_len + 4)
    w.writev(consume bytes)
    w.done()

  fun typeless_message(payload: Writer iso): Array[ByteSeq] val =>
    let w = Writer
    let payload_len = payload.size().u32()
    let bytes = payload.done()
    w.u32_be(payload_len + 4)
    w.writev(consume bytes)
    w.done()

  fun parameter_status(key: String, value: String): Array[ByteSeq] val =>
    let payload = Writer
    payload.write(key)
    payload.u8(0)
    payload.write(value)
    payload.u8(0)
    message('S', consume payload)

  fun authentication_ok(): Array[ByteSeq] val =>
    let payload = Writer
    payload.u32_be(0)
    message('R', consume payload)

  fun backend_key_data(pid: U32, secret: U32): Array[ByteSeq] val =>
    let payload = Writer
    payload.u32_be(pid)
    payload.u32_be(secret)
    message('K', consume payload)

  fun ready_for_query(status: U8): Array[ByteSeq] val =>
    let payload = Writer
    payload.u8(status)
    message('Z', consume payload)

  fun command_complete(tag': String): Array[ByteSeq] val =>
    let payload = Writer
    payload.write(tag')
    payload.u8(0)              // tag is a null-terminated string
    message('C', consume payload)

  fun client_startup(user: String, database: String): Array[ByteSeq] val =>
    let payload = Writer
    payload.u32_be(_Pg.v3())
    payload.write("user")
    payload.u8(0)
    payload.write(user)
    payload.u8(0)
    payload.write("database")
    payload.u8(0)
    payload.write(database)
    payload.u8(0)
    payload.u8(0)
    typeless_message(consume payload)

  fun password_message(password: String): Array[ByteSeq] val =>
    let payload = Writer
    payload.write(password)
    payload.u8(0)
    message('p', consume payload)
