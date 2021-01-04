
import os
import sdl2, sdl2/[audio]
import dav1d, nestegg, opus

import lov/player

export Player

if isMainModule:

  assert paramCount() == 1, "please specify file to play on command line"
  case paramStr(1):
  of "--help":
    echo "Usage: lov [video.webm]"
    echo ""
    echo "video.webm must be an av1/opus-s16/webm video file"
  else:
    let filename = paramStr(1)
    let file = open(filename)
    let demuxer = newDemuxer(file)

    # init SDL
    let r = sdl2.init(INIT_EVERYTHING)
    if r.int < 0:
      raise newException(IOError, $getError())
    var
      width = demuxer.videoParams.width
      height = demuxer.videoParams.height

    var window = createWindow("lov", 100, 100, 100 + width.cint, 1 + height.cint, SDL_WINDOW_SHOWN)
    if window == nil:
      raise newException(IOError, $getError())

    # initialize audio
    let audioBufferSize = uint16((1.0 / 25) * demuxer.audioParams.rate.float * demuxer.audioParams.channels.float)
    let requested = AudioSpec(freq: 48000.cint, channels: 2.uint8, samples: audioBufferSize, format: AUDIO_S16LSB)
    var obtained = AudioSpec()
    let audioDevice = openAudioDevice(nil, 0, requested.unsafeAddr, obtained.unsafeAddr, 0)
    if audioDevice == 0:
      raise newException(IOError, $getError())

    let renderer = createRenderer(window, -1, RendererAccelerated or RendererPresentVsync)
    if renderer == nil:
      raise newException(IOError, $getError())

    let texture = createTexture(renderer, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, width.cint, height.cint)

    discard renderer.clear()
    discard renderer.copy(texture, nil, nil)
    renderer.present()

    var player = newPlayer(demuxer, window, texture, audioDevice)

    delay 500

    file.close

    destroy(renderer)
    destroy(texture)
    audioDevice.closeAudioDevice
    sdl2.quit()

