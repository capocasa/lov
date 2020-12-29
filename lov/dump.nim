import std/sha1

import nestegg, dav1d

proc dump*(data: ptr UncheckedArray[byte], len: int): string =
  "UncheckedArray[byte], len/" & $len & " " & $secureHash(toOpenArray(cast[cstring](data), 0, len))

proc dump*(chunk: Chunk): string =
  "Chunk/" & $chunk.len & " " & $secureHash(toOpenArray(cast[cstring](chunk.data), 0, chunk.len.int))

proc dump*(data: Data): string =
  "Data/" & $data.raw.sz & " " & $secureHash(toOpenArray(cast[cstring](data.raw.data), 0, data.raw.sz.int))


