import math, dav1d
import sdl2, sdl2/[gfx, audio]

## Nim sdl2 helper functions for Nim's official wrapper.

# --- additional sdl2 wrapper code ---

when not defined(SDL_Static):
  {.push callConv: cdecl, dynlib: LibName}

proc updateYUVTexture*(texture: TexturePtr, rect: ptr Rect, yPlane: ptr uint8,
                       yPitch: cint, uPlane: ptr uint8,  uPitch: cint, vPlane: ptr uint8,
                       vPitch: cint): SDL_Return
                       {.importc: "SDL_UpdateYUVTexture", discardable.}
  ## Wrap hardware-accelerated YUV texture update, lacking in standard Nim sdl2

proc clearQueuedAudio*(dev: AudioDeviceID)
                       {.importc: "SDL_ClearQueuedAudio"}
  ## clear audio queue

when not defined(SDL_Static):
  {.pop}



# --- end of additional sdl2 wrapper code ---

proc update*(texture: TexturePtr, pic: dav1d.Picture) =

  assert PIXEL_LAYOUT_I420 == pic.raw.p.layout, "i420 required"
  assert pic.raw.p.bpc == 8, "8 bits required"

  ## A update an SDL texture with a frame in the dav1d's av1 decoder's output format
  if 0.SDL_Return != updateYUVTexture(texture, nil,
    cast[ptr byte](pic.raw.data[0]), pic.raw.stride[0].cint, # Y
    cast[ptr byte](pic.raw.data[1]), pic.raw.stride[1].cint, # U
    cast[ptr byte](pic.raw.data[2]), pic.raw.stride[1].cint  # V
  ):
    raise newException(ValueError, $getError())

proc setFramerate*(manager: var FpsManager, rate: float) =
  if rate < FPS_LOWER_LIMIT or rate > FPS_UPPER_LIMIT:
    raise newException(RangeDefect, "framerate must be between $# and $#" % [$FPS_LOWER_LIMIT, $FPS_UPPER_LIMIT])
  manager.framecount = 0
  manager.rate = round(rate).cint
  manager.rateticks = 1000.0 * round(rate) / (rate * rate)

