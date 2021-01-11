import os
import sdl2, sdl2/[audio, gfx], lov/sdl2_aux
import lov, nestegg, dav1d, opus

### aux function
proc update(texture: TexturePtr, pic: Picture) =
  ## A helper function to streamingly update an SDL texture
  ## with a frame in dav1d's output format
  if 0.SDL_Return != updateYUVTexture(texture, nil,
    cast[ptr byte](pic.raw.data[0]), pic.raw.stride[0].cint, # Y
    cast[ptr byte](pic.raw.data[1]), pic.raw.stride[1].cint, # U
    cast[ptr byte](pic.raw.data[2]), pic.raw.stride[1].cint  # V
  ):
    raise newException(ValueError, $getError())

### init configuration from command line params
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
let l = newLov(demuxer)

### init SDL
if 0.SDL_return < sdl2.init(INIT_EVERYTHING):
  raise newException(IOError, $getError())

var
  fps = demuxer.firstVideo.fps

var window = createWindow(
  "lov",
  SDL_WINDOWPOS_UNDEFINED_MASK,
  SDL_WINDOWPOS_UNDEFINED_MASK,
  demuxer.firstVideo.videoParams.width.cint,
  demuxer.firstVideo.videoParams.height.cint,
  SDL_WINDOW_SHOWN or SDL_WINDOW_RESIZABLE or SDL_WINDOW_INPUT_FOCUS
)

if window == nil:
  raise newException(IOError, $getError())

let renderer = createRenderer(window, -1, RendererAccelerated or RendererPresentVsync)
  # create SDL renderer
if renderer == nil:
  raise newException(IOError, $getError())

renderer.setDrawColor(0, 0, 0)

discard renderer.setLogicalSize(demuxer.firstVideo.videoParams.width.cint, demuxer.firstVideo.videoParams.height.cint)
  # keep aspect ratio and handle window resizes

let texture = createTexture(renderer, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, demuxer.firstVideo.videoParams.width.cint, demuxer.firstVideo.videoParams.height.cint)
  # create texture, the video will render to this 

if 0 != renderer.clear():
  raise newException(IOError, $getError())

# initialize SDL audio
let audioBufferSize = uint16((1.0 / fps) * demuxer.firstAudio.audioParams.rate.float * demuxer.firstAudio.audioParams.channels.float)
let requested = AudioSpec(freq: 48000.cint, channels: 2.uint8, samples: audioBufferSize, format: AUDIO_S16LSB)
var obtained = AudioSpec()
let audioDevice = openAudioDevice(nil, 0, requested.unsafeAddr, obtained.unsafeAddr, 0)
if audioDevice == 0:
  raise newException(IOError, $getError())
audioDevice.pauseAudioDevice(0)

### present video frames and audio samples

var
  run = true
  play = true
  evt = sdl2.defaultEvent
  fpsman: FpsManager
  timestamp: culonglong

fpsman.init
fpsman.setFramerate(fps)

while run:
  var
    targetRect = rect(0.cint, 0.cint, demuxer.firstVideo.videoParams.width.cint, demuxer.firstVideo.videoParams.height.cint)

  while pollEvent(evt):
    case evt.kind:
    of QuitEvent:
      run = false
      break
    of KeyDown:
      case evt.key.keysym.sym:
      of K_SPACE:
        # play = not play
        if play:
          play = false
        else:
          play = true
      of K_ESCAPE, K_Q:
        run = false
        break
      of K_HOME:
        l.seek(0)
      else:
        discard
    else:
      discard

  while play:
    # if playing, keep getting packets until next video frame

    let packet = l.getPacket()
      # wait for a packet containing a demuxed packet

    case packet.kind:

    of pktVideo:
      # show a video frame from the queue
      # a new packet will be demuxed automagically to the channel queue
      try:
        texture.update(packet.picture)
      except ValueError:
        # TODO: warn
        discard
      timestamp = packet.timestamp
      break

    of pktAudio:
      # play back a chunk of audio data from the queue
      # a new packet will be demuxed automagically in the demuxer thread to refill the channel queue
      let r = audioDevice.queueAudio(packet.samples.data, packet.samples.bytes.uint32)
      if r != 0:
        raise newException(IOError, $getError())

    of pktDone:
      play = false

  if 0 != renderer.clear():
    raise newException(IOError, $getError())
  if 0.SDL_Return != renderer.copy(texture, nil, nil):
    raise newException(IOError, $getError())
  fpsman.delay
  renderer.present()

destroy(renderer)
destroy(texture)
audioDevice.closeAudioDevice
sdl2.quit()
file.close

