primitive Cat
  fun apply(a: Array[U8] val, b: Array[U8] val): Array[U8] val =>
    if a.size() == 0 then
      b
    else
      recover val Array[U8](a.size() + b.size()) .> append(a) .> append(b) end
    end
