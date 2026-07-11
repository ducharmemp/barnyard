use "../harness"
use "buffered"
use "collections"
use "pony_test"

class \nodoc\ iso _WireFrameRoundtrip is UnitTest
  fun name(): String => "wire/frame_roundtrip"

  fun apply(h: TestHelper) =>
    for size in Range[USize](0, 65) do
      for t in [as U8: 'R'; 'Z'; 0; 0xFF].values() do
        let body = recover val Array[U8].init((size and 0xFF).u8(), size) end
        let payload = recover iso Writer end
        payload.write(body)
        let flat = Flat(PgWire.message(t, consume payload))
        h.assert_eq[USize](size + 5, flat.size())
        try
          h.assert_eq[U8](t, flat(0)?)
          let declared =
            (flat(1)?.u32() << 24) or (flat(2)?.u32() << 16)
              or (flat(3)?.u32() << 8) or flat(4)?.u32()
          h.assert_eq[U32]((size + 4).u32(), declared)
        else
          h.fail("frame shorter than header")
        end
        match FrameHeader.parse(flat)
        | (let t': U8, let blen: USize) =>
          h.assert_eq[U8](t, t')
          h.assert_eq[USize](size, blen)
        | None =>
          h.fail("parse failed for body size " + size.string())
        end
      end
    end

class \nodoc\ iso _WireKnownMessageLiterals is UnitTest
  fun name(): String => "wire/known_message_literals"

  fun apply(h: TestHelper) =>
    EqBytes(h,
      recover val [as U8: 'R'; 0; 0; 0; 8; 0; 0; 0; 0] end,
      Flat(PgWire.authentication_ok()), "authentication_ok")
    EqBytes(h,
      recover val [as U8: 'Z'; 0; 0; 0; 5; 'I'] end,
      Flat(PgWire.ready_for_query('I')), "ready_for_query")
    EqBytes(h,
      Cat(recover val [as U8: 'S'; 0; 0; 0; 8] end, "k\0v\0".array()),
      Flat(PgWire.parameter_status("k", "v")), "parameter_status")
    EqBytes(h,
      recover val [as U8: 'K'; 0; 0; 0; 12; 0; 0; 0; 123; 0; 0; 1; 200] end,
      Flat(PgWire.backend_key_data(123, 456)), "backend_key_data")
    EqBytes(h,
      Cat(recover val [as U8: 'p'; 0; 0; 0; 11] end, "sekret\0".array()),
      Flat(PgWire.password_message("sekret")), "password_message")

class \nodoc\ iso _WireClientStartupLayout is UnitTest
  fun name(): String => "wire/client_startup_layout"

  fun apply(h: TestHelper) =>
    EqBytes(h, StartupLiteral(),
      Flat(PgWire.client_startup("alice", "db1")), "client_startup")
    let other = Flat(PgWire.client_startup("bob", "warehouse"))
    try
      let declared =
        (other(0)?.u32() << 24) or (other(1)?.u32() << 16)
          or (other(2)?.u32() << 8) or other(3)?.u32()
      h.assert_eq[U32](other.size().u32(), declared)
      h.assert_eq[U8](0, other(other.size() - 1)?)
      h.assert_eq[U8](0, other(other.size() - 2)?)
    else
      h.fail("startup packet too short")
    end

class \nodoc\ iso _WireFrameHeaderBoundaries is UnitTest
  fun name(): String => "wire/frame_header_boundaries"

  fun apply(h: TestHelper) =>
    match FrameHeader.parse(recover val [as U8: 'Q'; 0; 0; 0; 3] end)
    | None => None
    else
      h.fail("declared length 3 accepted")
    end
    match FrameHeader.parse(recover val [as U8: 'S'; 0; 0; 0; 4] end)
    | (let t: U8, let blen: USize) =>
      h.assert_eq[U8]('S', t)
      h.assert_eq[USize](0, blen)
    else
      h.fail("zero-body frame rejected")
    end
    match FrameHeader.parse(recover val [as U8: 'Z'; 0; 0; 0; 5] end)
    | (let t: U8, let blen: USize) =>
      h.assert_eq[U8]('Z', t)
      h.assert_eq[USize](1, blen)
    else
      h.fail("one-byte body frame rejected")
    end
    match FrameHeader.parse(recover val [as U8: 'Q'; 0; 0] end)
    | None => None
    else
      h.fail("short input accepted")
    end

