primitive FrameHeader
  fun parse(data: ByteSeq val): ((U8, USize) | None) =>
    let bytes =
      match data
      | let a: Array[U8] val => a
      | let s: String => s.array()
      end
    if bytes.size() < 5 then
      return None
    end
    parse_at(bytes, 0)

  fun parse_at(bytes: Array[U8] val, at: USize): ((U8, USize) | None) =>
    if (bytes.size() - at) < 5 then
      return None
    end
    try
      let msg_type = bytes(at)?
      let len =
        (bytes(at + 1)?.u32() << 24) or (bytes(at + 2)?.u32() << 16)
          or (bytes(at + 3)?.u32() << 8) or bytes(at + 4)?.u32()
      if len < 4 then
        return None
      end
      (msg_type, len.usize() - 4)
    else
      None
    end

primitive Char
  fun apply(b: U8): String =>
    if (b >= 0x20) and (b < 0x7f) then
      recover val String(3).>push('\'').>push(b).>push('\'') end
    else
      b.string()
    end
