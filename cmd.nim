import os
import sdl2, sdl2/[audio, gfx], lov/sdl2_aux
import lov, nestegg, dav1d, opus

# aux function
proc update(texture: TexturePtr, pic: Picture) =
  ## A helper function to streamingly update an SDL texture
  ## with a frame in dav1d's output format
  if 0.SDL_return != updateYUVTexture(texture, nil,
    cast[ptr byte](pic.raw.data[0]), pic.raw.stride[0].cint, # Y
    cast[ptr byte](pic.raw.data[1]), pic.raw.stride[1].cint, # U
    cast[ptr byte](pic.raw.data[2]), pic.raw.stride[1].cint  # V
  ):
    raise newException(ValueError, $getError())

# init configuration from command line params
assert paramCount() == 1, "please specify file to play on command line"

var filename:string

case paramStr(1):
of "--help":
  echo "Usage: lov [video.webm]"
  echo ""
  echo "video.webm must be an av1/opus-s16/webm video file"
  quit 127
else:
  filename = paramStr(1)

var file = filename.open
var demuxer = newDemuxer(file)

# init SDL
if 0.SDL_return < sdl2.init(INIT_EVERYTHING):
  raise newException(IOError, $getError())

var
  width = demuxer.videoParams.width
  height = demuxer.videoParams.height

var window = createWindow("lov", 100, 100, 100 + width.cint, 1 + height.cint, SDL_WINDOW_SHOWN)
if window == nil:
  raise newException(IOError, $getError())

# initialize SDL audio
let audioBufferSize = uint16((1.0 / 25) * demuxer.audioParams.rate.float * demuxer.audioParams.channels.float)
let requested = AudioSpec(freq: 48000.cint, channels: 2.uint8, samples: audioBufferSize, format: AUDIO_S16LSB)
var obtained = AudioSpec()
let audioDevice = openAudioDevice(nil, 0, requested.unsafeAddr, obtained.unsafeAddr, 0)
if audioDevice == 0:
  raise newException(IOError, $getError())

# create SDL renderer
let renderer = createRenderer(window, -1, RendererAccelerated or RendererPresentVsync)
if renderer == nil:
  raise newException(IOError, $getError())

# creat texture, the video will render to this 
let texture = createTexture(renderer, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, width.cint, height.cint)

discard renderer.clear()
discard renderer.copy(texture, nil, nil)
renderer.present()

# init decoding
let l = newLov(demuxer)

# present video frames and audio samples

var
  run = true
  fpsman: FpsManager

fpsman.init
if 0.SDL_return != fpsman.setFramerate(25):
  raise newException(IOError, $getError())

while run:

  # wait for a packet containing a demuxed packet
  let packet = l.packet[].recv()

  case packet.kind:

  of pktVideo:
    # show a video frame from the queue
    # a new packet will be demuxed automagically to the channel queue
    texture.update(packet.picture)
    discard renderer.clear()
    discard renderer.copy(texture, nil, nil)
    
    fpsman.delay

    renderer.present()

  of pktAudio:
    # play back a chunk of audio data from the queue
    # a new pakcet will be demuxed automagically to the channel queue
    let r = audioDevice.queueAudio(packet.samples.data, packet.samples.bytes.uint32)
    if r != 0:
      raise newException(IOError, $getError())

  of pktDone:
    run = false

delay 500

destroy(renderer)
destroy(texture)
audioDevice.closeAudioDevice
sdl2.quit()
file.close

