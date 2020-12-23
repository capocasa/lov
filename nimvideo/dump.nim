import std/sha1

import nestegg, dav1d

proc dump(data: ptr uint8, size: uint): string =
  "ptr uint8, size/" & $secureHash(toOpenArray(cast[cstring](data), 0, size.int))

proc dump(chunk: Chunk): string =
  "Chunk/" & $secureHash(toOpenArray(cast[cstring](chunk.data), 0, chunk.size.int))

proc dump(data: Data): string =
  "Data/" & $secureHash(toOpenArray(cast[cstring](data.raw.data), 0, data.raw.sz.int))


