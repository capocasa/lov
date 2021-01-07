import sdl2

when not defined(SDL_Static):
  {.push callConv: cdecl, dynlib: LibName.}

proc updateYUVTexture*(texture: TexturePtr, rect: ptr Rect, yPlane: ptr uint8, yPitch: cint, uPlane: ptr uint8,
                       uPitch: cint, vPlane: ptr uint8, vPitch: cint): SDL_Return {.importc: "SDL_UpdateYUVTexture", discardable.}
  ## Wrap hardware-accelerated YUV texture updater

