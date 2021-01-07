import math
import sdl2, sdl2/[gfx]

proc setFramerate*(manager: var FpsManager, rate: float) =
  if rate < FPS_LOWER_LIMIT or rate > FPS_UPPER_LIMIT:
    raise newException(RangeDefect, "framerate must be between $# and $#" % [$FPS_LOWER_LIMIT, $FPS_UPPER_LIMIT])
  manager.framecount = 0
  manager.rate = round(rate).cint
  manager.rateticks = 1000.0 * round(rate) / (rate * rate)

when not defined(SDL_Static):
  {.push callConv: cdecl, dynlib: LibName.}

proc updateYUVTexture*(texture: TexturePtr, rect: ptr Rect, yPlane: ptr uint8, yPitch: cint, uPlane: ptr uint8,
                       uPitch: cint, vPlane: ptr uint8, vPitch: cint): SDL_Return {.importc: "SDL_UpdateYUVTexture", discardable.}
  ## Wrap hardware-accelerated YUV texture updater

