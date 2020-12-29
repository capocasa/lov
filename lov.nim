
import sdl2, sdl2/[audio]
import dav1d, nestegg, opus, deques 

import lov/[dump, sdl2_aux]

type
  InitException = object of IOError

const
  width = 720
  height = 480
  fps = 25
  rate = 48000
  channels = chStereo
  audioBufferSize = 1024
  # audioBufferSize = uint16((1.0 / fps) * rate.float * channels.float)
    # samples to fill one video frame

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

let requested = AudioSpec(freq: rate, channels: channels.uint8, samples: audioBufferSize, format: AUDIO_S16LSB)
var obtained = AudioSpec()
var audioDevice = openAudioDevice(nil, 0, requested.unsafeAddr, obtained.unsafeAddr, 0)

echo $requested
echo $obtained

#audioDevice.pauseAudioDevice(0)

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

import random

#[
for i in 0..100:
  var samples:Samples
  new(samples)
  samples.data = cast[ptr UncheckedArray[int16]](alloc(1800 * 2))
  samples.len = 1800
  for i in 0..<samples.len:
    samples.data[i] = rand(int16) div 2
  
  let r = audioDevice.queueAudio(samples.data, samples.bytes.uint32)
  if r != 0:
    raise newException(IOError, $getError())
]#

var pics = initDeque[Picture]()
var frames = initDeque[Samples]()

for packet in demuxer:

  case packet.track.kind:
  of tkAudio:
    echo "audio $# packet timestamp $#" % [$packet.track.audioCodec, $packet.timestamp]
    echo $packet.track.audio_params
    case packet.track.audioCodec:
    of acOpus:
      for chunk in packet:
        let samples = opusDecoder.decode(chunk.data, chunk.len)
        #[
        var samples:Samples
        new(samples)
        samples.data = cast[ptr UncheckedArray[int16]](alloc(1800 * 2))
        samples.len = 1800
        for i in 0..<samples.len:
          samples.data[i] = rand(int16) div 2
        ]#
        frames.addLast(samples)
    else:
      raise newException(ValueError, "codec $# not supported" % $packet.track.audioCodec)
  of tkVideo:
    echo "video $# packet timestamp $# " % [$packet.track.videoCodec, $packet.timestamp]
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
        var pic:Picture
        try:
          pic = av1Decoder.getPicture()
        except BufferError:
          # TODO: handle
          raise getCurrentException()
        
        pics.addLast(pic)
    else:
      # TODO: handle unknown packet codec
      discard
  else:
    # TODO: handle packet
    discard

for samples in frames:
  let r = audioDevice.queueAudio(samples.data, samples.bytes.uint32)
  if r != 0:
    raise newException(IOError, $getError())

var remainingPerfsInFrame: uint64
var remainingMsInFrame: uint64
let perfsPerSecond = getPerformanceFrequency()
let perfsPerFrame = perfsPerSecond div fps.uint64
var currentTimeInPerfs: uint64

audioDevice.pauseAudioDevice(0)

var nextFrameInPerfs = getPerformanceCounter() + perfsPerFrame
for pic in pics:
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
  nextFrameInPerfs += perfsPerFrame

delay 500

destroy(renderer)
destroy(texture)
close(file)
audioDevice.closeAudioDevice

sdl2.quit()

