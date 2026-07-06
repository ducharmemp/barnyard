use "itertools"

class IterReader
  var _iter: Iterator[U8]

  new create(source: ByteSeq val) =>
    _iter = match source
    | let s: String => s.array().values()
    | let a: Array[U8] val => a.values()
    end

  fun ref _byte(): U8 ? => _iter.next()?

  fun ref u8(): U8 ? => _byte()?

  fun ref i8(): I8 ? => _byte()?.i8()

  fun ref u16_be(): U16 ? =>
    let b0 = _byte()?.u16()
    let b1 = _byte()?.u16()
    (b0 << 8) or b1

  fun ref u16_le(): U16 ? =>
    let b0 = _byte()?.u16()
    let b1 = _byte()?.u16()
    (b1 << 8) or b0

  fun ref i16_be(): I16 ? => u16_be()?.i16()

  fun ref i16_le(): I16 ? => u16_le()?.i16()

  fun ref u32_be(): U32 ? =>
    let b0 = _byte()?.u32()
    let b1 = _byte()?.u32()
    let b2 = _byte()?.u32()
    let b3 = _byte()?.u32()
    (b0 << 24) or (b1 << 16) or (b2 << 8) or b3

  fun ref u32_le(): U32 ? =>
    let b0 = _byte()?.u32()
    let b1 = _byte()?.u32()
    let b2 = _byte()?.u32()
    let b3 = _byte()?.u32()
    (b3 << 24) or (b2 << 16) or (b1 << 8) or b0

  fun ref i32_be(): I32 ? => u32_be()?.i32()

  fun ref i32_le(): I32 ? => u32_le()?.i32()

  fun ref u64_be(): U64 ? =>
    let b0 = _byte()?.u64()
    let b1 = _byte()?.u64()
    let b2 = _byte()?.u64()
    let b3 = _byte()?.u64()
    let b4 = _byte()?.u64()
    let b5 = _byte()?.u64()
    let b6 = _byte()?.u64()
    let b7 = _byte()?.u64()
    (b0 << 56) or (b1 << 48) or (b2 << 40) or (b3 << 32)
      or (b4 << 24) or (b5 << 16) or (b6 << 8) or b7

  fun ref u64_le(): U64 ? =>
    let b0 = _byte()?.u64()
    let b1 = _byte()?.u64()
    let b2 = _byte()?.u64()
    let b3 = _byte()?.u64()
    let b4 = _byte()?.u64()
    let b5 = _byte()?.u64()
    let b6 = _byte()?.u64()
    let b7 = _byte()?.u64()
    (b7 << 56) or (b6 << 48) or (b5 << 40) or (b4 << 32)
      or (b3 << 24) or (b2 << 16) or (b1 << 8) or b0

  fun ref i64_be(): I64 ? => u64_be()?.i64()

  fun ref i64_le(): I64 ? => u64_le()?.i64()

  fun ref u128_be(): U128 ? =>
    let hi = u64_be()?.u128()
    let lo = u64_be()?.u128()
    (hi << 64) or lo

  fun ref u128_le(): U128 ? =>
    let lo = u64_le()?.u128()
    let hi = u64_le()?.u128()
    (hi << 64) or lo

  fun ref i128_be(): I128 ? => u128_be()?.i128()

  fun ref i128_le(): I128 ? => u128_le()?.i128()

  fun ref f32_be(): F32 ? => F32.from_bits(u32_be()?)

  fun ref f32_le(): F32 ? => F32.from_bits(u32_le()?)

  fun ref f64_be(): F64 ? => F64.from_bits(u64_be()?)

  fun ref f64_le(): F64 ? => F64.from_bits(u64_le()?)

  fun ref skip(n: USize) =>
    Iter[U8](_iter).skip(n)

  fun ref block(len: USize): Array[U8] iso^ ? =>
    let out = recover iso Array[U8](len) end
    var i: USize = 0
    while i < len do
      out.push(_byte()?)
      i = i + 1
    end
    consume out

  fun ref read_until(separator: U8): Array[U8] iso^ ? =>
    let out = recover iso Array[U8] end
    while true do
      let b = _byte()?
      if b == separator then break end
      out.push(b)
    end
    consume out

  fun ref line(keep_line_breaks: Bool = false): String iso^ ? =>
    let out = recover iso String end
    while true do
      let b = _byte()?
      if b == '\n' then
        if keep_line_breaks then out.push(b) end
        break
      end
      out.push(b)
    end
    if not keep_line_breaks then
      try
        if (out.size() > 0) and (out.at_offset(-1)? == '\r') then
          out.truncate(out.size() - 1)
        end
      end
    end
    consume out
