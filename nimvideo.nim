
import sdl2
import dav1d, nestegg, opus

import nimvideo/[dump, sdl2_aux]

template newData(chunk: Chunk): Data =
  let data:ptr cuchar = chunk.data
    # enforce expected type before cast
  newData(cast[ptr uint8](data), chunk.size.uint)

const
  width = 720
  height = 480
  fps = 25
  rate = 48000
  channels = 2

var
  window: WindowPtr
  renderer: RendererPtr
  texture: TexturePtr

discard sdl2.init(INIT_EVERYTHING)

window = createWindow("nimvideo", 100, 100, 100 + width, 1 + height, SDL_WINDOW_SHOWN)
if window == nil:
  echo("createWindow Error: ", getError())
  quit(1)

renderer = createRenderer(window, -1, RendererAccelerated or RendererPresentVsync)
if renderer == nil:
  echo("createRenderer Error: ", getError())
  quit(1)

texture = createTexture(renderer, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, width, height)

discard renderer.clear()
discard renderer.copy(texture, nil, nil)
renderer.present()

var file = open("resources/test.webm")

var demuxer = newDemuxer(file)

var av1Decoder = dav1d.newDecoder()

var opusDecoder = opus.newDecoder(sr48k, chStereo)

proc update(texture: TexturePtr, pic: Picture) =
  let r = updateYUVTexture(texture, nil,
    cast[ptr byte](pic.raw.data[0]), pic.raw.stride[0].cint, # Y
    cast[ptr byte](pic.raw.data[1]), pic.raw.stride[1].cint, # U
    cast[ptr byte](pic.raw.data[2]), pic.raw.stride[1].cint  # V
  )

proc update(renderer: RendererPtr, texture: TexturePtr) =
  discard renderer.clear()
  discard renderer.copy(texture, nil, nil)

var timestamp: culonglong
var newframe = false

var remainingPerfsInFrame: uint64
var remainingMsInFrame: uint64
let perfsPerSecond = getPerformanceFrequency()
let perfsPerFrame = perfsPerSecond div fps.uint64
var currentTimeInPerfs: uint64
var nextFrameInPerfs = getPerformanceCounter()

var empty:bool

for packet in demuxer:
  empty = false
  newframe = false

  case packet.track.kind:
  of tkAudio:
    echo "audio $# packet" % $packet.track.audioCodec
    echo $packet.track.audio_params
  of tkVideo:
    echo "video $# packet" % $packet.track.videoCodec
    echo $packet.track.video_params
    case packet.track.videoCodec:
    of vcAv1:
      newframe = true
      echo "send data chunk to decoder"
      for chunk in packet:
        var data = newData(chunk)
        try:
          av1Decoder.send(data)
        except BufferError:
          echo "buffer empty, exiting"
          empty = true
            # TODO: handle and continue
    else:
      discard
  else:
    echo "unknown packet"

  if empty:
    break

  if newframe:
    nextFrameInPerfs += perfsPerFrame
    try:
      let pic = av1Decoder.getPicture()
      texture.update(pic)
      renderer.update(texture)

      currentTimeInPerfs = getPerformanceCounter()
      if nextFrameInPerfs < currentTimeInPerfs:
        # TODO: warn or respond
        remainingPerfsInFrame = 0
      else:
        remainingPerfsInFrame = nextFrameInPerfs - currentTimeInPerfs
      remainingMsInFrame = (remainingPerfsInFrame * 1000) div perfsPerSecond
      echo "perfsPerFrame: ", $perfsPerFrame, " perfsPerSecond: ", $perfsPerSecond, " remainingPerfsInFrame: ", $remainingPerfsInFrame, " remainingMsInFrame: ", $remainingMsInFrame
      delay remainingMsInFrame.uint32
      renderer.present()
    except BufferError:
      echo "skipping picture"
      continue
    except DecodeError:
      echo "decode error"
      break

delay 500

destroy(renderer)
destroy(texture)
close(file)

sdl2.quit()

