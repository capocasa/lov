
import sdl2, sdl2/[audio]
import dav1d, nestegg, opus

import nimvideo/[dump, sdl2_aux]

type
  InitException = object of IOError

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
  raise newException(InitException, $getError())

renderer = createRenderer(window, -1, RendererAccelerated or RendererPresentVsync)
if renderer == nil:
  raise newException(InitException, $getError())

texture = createTexture(renderer, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, width, height)

discard renderer.clear()
discard renderer.copy(texture, nil, nil)
renderer.present()

let requested = AudioSpec(freq: 48000, channels: 2, samples: 128)
var obtained = AudioSpec()
var audioDevice = openAudioDevice(nil, 0, requested.unsafeAddr, obtained.unsafeAddr, 0)

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
  if r != 0.SDL_return:
    raise newException(ValueError, "yuv updated failed")

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

pauseAudio(0)

for packet in demuxer:
  empty = false
  newframe = false

  case packet.track.kind:
  of tkAudio:
    echo "audio $# packet" % $packet.track.audioCodec
    echo $packet.track.audio_params
    case packet.track.audioCodec:
    of acOpus:
      for chunk in packet:
        let pcm = opusDecoder.decode(chunk.data, chunk.len)
        let r = audioDevice.queueAudio(pcm.data, pcm.len.cuint)
        if r != 0:
          raise newException(IOError, $getError())
    else:
      raise newException(ValueError, "codec $# not supported" % $packet.track.audioCodec)
  of tkVideo:
    echo "video $# packet" % $packet.track.videoCodec
    echo $packet.track.video_params
    case packet.track.videoCodec:
    of vcAv1:
      for chunk in packet:
        try:
          av1Decoder.send(chunk.data, chunk.len)
        except BufferError:
          # TODO: handle
          raise getCurrentException()

        # video decode and delay for timing source
        nextFrameInPerfs += perfsPerFrame
        var pic:Picture
        try:
          pic = av1Decoder.getPicture()
        except BufferError:
          # TODO: handle
          raise getCurrentException()
        texture.update(pic)
        renderer.update(texture)

        currentTimeInPerfs = getPerformanceCounter()
        if nextFrameInPerfs < currentTimeInPerfs:
          # TODO: handle frame slowdown
          remainingPerfsInFrame = 0
        else:
          remainingPerfsInFrame = nextFrameInPerfs - currentTimeInPerfs
        remainingMsInFrame = (remainingPerfsInFrame * 1000) div perfsPerSecond
          # echo "perfsPerFrame: ", $perfsPerFrame, " perfsPerSecond: ", $perfsPerSecond, " remainingPerfsInFrame: ", $remainingPerfsInFrame, " remainingMsInFrame: ", $remainingMsInFrame
        delay remainingMsInFrame.uint32
          # main timing source
        renderer.present()
          # show when everything else has been done
    else:
      # TODO: handle unknown packet codec
      discard
  else:
    # TODO: handle packet
    discard


delay 500

destroy(renderer)
destroy(texture)
close(file)

sdl2.quit()

