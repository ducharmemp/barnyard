use "pony_test"

primitive \nodoc\ _CatBytes
  fun apply(a: Array[U8] val, b: Array[U8] val): Array[U8] val =>
    if a.size() == 0 then
      b
    else
      recover val Array[U8](a.size() + b.size()) .> append(a) .> append(b) end
    end

primitive \nodoc\ ToVal
  fun apply(a: Array[U8] box): Array[U8] val =>
    let out = recover iso Array[U8](a.size()) end
    for b in a.values() do out.push(b) end
    consume out

primitive \nodoc\ Flat
  fun apply(m: Array[ByteSeq] val): Array[U8] val =>
    recover val
      let out = Array[U8]
      for b in m.values() do
        match b
        | let str: String => out.append(str.array())
        | let arr: Array[U8] val => out.append(arr)
        end
      end
      out
    end

primitive \nodoc\ Frame
  fun apply(t: U8, body: Array[U8] val): Array[U8] val =>
    let len = (body.size() + 4).u32()
    recover val
      Array[U8](body.size() + 5)
        .> push(t)
        .> push((len >> 24).u8())
        .> push((len >> 16).u8())
        .> push((len >> 8).u8())
        .> push(len.u8())
        .> append(body)
    end

primitive \nodoc\ SplitFrames
  fun apply(bytes: Array[U8] val): Array[(U8, Array[U8] val)] val =>
    recover val
      let out = Array[(U8, Array[U8] val)]
      var rest = bytes
      while rest.size() >= 5 do
        try
          let t = rest(0)?
          let declared =
            (rest(1)?.usize() << 24) or (rest(2)?.usize() << 16)
              or (rest(3)?.usize() << 8) or rest(4)?.usize()
          if declared < 4 then break end
          let blen = declared - 4
          if rest.size() < (5 + blen) then break end
          out.push((t, rest.trim(5, 5 + blen)))
          rest = rest.trim(5 + blen)
        else
          break
        end
      end
      out
    end

primitive \nodoc\ EqBytes
  fun apply(h: TestHelper, expected: Array[U8] val, actual: Array[U8] box,
    label: String): Bool
  =>
    if expected.size() != actual.size() then
      h.fail(label + ": got " + actual.size().string() + " bytes, expected "
        + expected.size().string())
      return false
    end
    var i: USize = 0
    while i < expected.size() do
      try
        if expected(i)? != actual(i)? then
          h.fail(label + ": byte mismatch at offset " + i.string())
          return false
        end
      else
        h.fail(label + ": index error")
        return false
      end
      i = i + 1
    end
    true

primitive \nodoc\ Join
  fun apply(a: Array[String] box, sep: String = ","): String ref =>
    let out = String
    for s in a.values() do
      if out.size() > 0 then out.append(sep) end
      out.append(s)
    end
    out

primitive \nodoc\ Only
  fun apply(events: Array[String] box, keep: Array[String] val): Array[String] ref =>
    let out = Array[String]
    for e in events.values() do
      if keep.contains(e, {(l: String, r: String): Bool => l == r}) then
        out.push(e)
      end
    end
    out

primitive \nodoc\ Count
  fun apply(events: Array[String] box, needle: String): USize =>
    var n: USize = 0
    for e in events.values() do
      if e == needle then n = n + 1 end
    end
    n

primitive \nodoc\ StartupLiteral
  fun apply(): Array[U8] val =>
    _CatBytes(
      recover val [as U8: 0; 0; 0; 33; 0; 3; 0; 0] end,
      "user\0alice\0database\0db1\0\0".array())

primitive \nodoc\ SslRequest
  fun apply(): Array[U8] val =>
    recover val [as U8: 0; 0; 0; 8; 0x04; 0xD2; 0x16; 0x2F] end

primitive \nodoc\ GssRequest
  fun apply(): Array[U8] val =>
    recover val [as U8: 0; 0; 0; 8; 0x04; 0xD2; 0x16; 0x30] end
