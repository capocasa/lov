import os, times
import sdl2, sdl2/[audio, gfx], lov/sdl2_aux
import lov, nestegg, opus

### init configuration from command line params
assert paramCount() == 1, "please specify file to play on command line"

var l:Lov

case paramStr(1):
of "--help":
  echo "Usage: lov [video.webm]"
  echo ""
  echo "video.webm must be an av1/opus-s16/webm video file"
  echo ""
  echo "During playback:"
  echo ""
  echo "SPACE      Start/Stop playback"
  echo "ESC/Q      Exit"
  echo "HOME       Skip to beginning"
  echo "PAGE UP    Skip back 1 minute"
  echo "PAGE DOWN  Skip forward 1 minute"
  echo "UP         Skip forward 10 seconds"
  echo "DOWN       Skip forward 10 seconds"
  echo "LEFT       Skip back 1 seconds"
  echo "RIGHT      Skip forward 1 second"
  quit 127
else:
  l = newLov(paramStr(1), 20)

let verbose = true

### init SDL
if 0.SDL_return < sdl2.init(INIT_EVERYTHING):
  raise newException(IOError, $getError())

var
  fps = l.demuxer.firstVideo.fps
  width = l.demuxer.firstVideo.videoParams.width
  height = l.demuxer.firstVideo.videoParams.height
  rate = l.demuxer.firstAudio.audioParams.rate
  channels = l.demuxer.firstAudio.audioParams.channels

var window = createWindow(
  "lov",
  SDL_WINDOWPOS_UNDEFINED_MASK,
  SDL_WINDOWPOS_UNDEFINED_MASK,
  width.cint,
  height.cint,
  SDL_WINDOW_SHOWN or SDL_WINDOW_RESIZABLE or SDL_WINDOW_INPUT_FOCUS
)

if window == nil:
  raise newException(IOError, $getError())

let renderer = createRenderer(window, -1, RendererAccelerated or RendererPresentVsync)
  # create SDL renderer
if renderer == nil:
  raise newException(IOError, $getError())

renderer.setDrawColor(0, 0, 0)

discard renderer.setLogicalSize(width.cint, height.cint)
  # keep aspect ratio and handle window resizes

let texture = createTexture(renderer, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, width.cint, height.cint)
  # create texture, the video will render to this 

if 0 != renderer.clear():
  raise newException(IOError, $getError())

type
  AudioDataObj = object
    lov: Lov
    samples: Samples
    position: int
    timestamp: culonglong
    timerCount: uint64
  AudioData = ref AudioDataObj

proc audioCallback(inputData: pointer; output: ptr uint8; bytesToWrite: cint) {.cdecl.} =
  var
    # cast data to useful structure
    inputData = cast[AudioData](inputData)
    
    # use an array as output buffer to be as safe as possible while interoperating with C
    output = cast[ptr UncheckedArray[byte]](output)

    # use an array as input buffer to be as safe as possible while interoperating with C
    input: ptr UncheckedArray[byte]

    # record how many samples were already read from the current input
    inputPosition: int

    # record how long the current chunk is
    bytesToRead: int
  
    # record how many samples were written to the output
    outputPosition = 0

  # initialize input variables if there is an input,
  # otherwise let input loading code do that
  if inputData.samples != nil:
    bytesToRead = inputData.samples.bytes
    input = cast[ptr UncheckedArray[byte]](inputData.samples.data)
    inputPosition = inputData.position

  # keep going until bytesToWrite samples were written
  while outputPosition < bytesToWrite:

    # get another chunk of decoded samples from the queue
    if inputData.samples == nil:
      let queueSize = inputData.lov.samples[].peek()
      if queueSize == 0:
        # Emit silence if there is a buffer underrun
        # this only works because this is the only audio thread consuming audio frames
        # it should really be using tryRecv, but that failed a lot even with
        # a populated queue
        let nextBytes = bytesToWrite - outputPosition
        if verbose:
          stderr.write "frames available: ", $inputData.lov.samples[].peek(), "\n"
          stderr.write "audio buffer underrun, skipping ", nextBytes div (sizeof(int16) * chStereo.int), " frames\n"
        zeroMem(output[outputPosition].addr, nextBytes)
        break
      (inputData.samples, inputData.timestamp) = inputData.lov.samples[].recv()
      bytesToRead = inputData.samples.bytes
      input = cast[ptr UncheckedArray[byte]](inputData.samples.data)
      inputPosition = 0
      inputData.timerCount = getPerformanceCounter()

    # write as many samples as can without loading another chunk of decoded samples,
    # and without overflowing the output buffer
    let nextBytes = min(bytesToRead - inputPosition, bytesToWrite - outputPosition)

    # do the actual writing. note taking the address from an array access is
    # a convenient alternative to pointer arithmetic that is as safe as is possible
    # for C-interoperable code
    copyMem(output[outputPosition].addr, input[inputPosition].addr, nextBytes)
    inputPosition += nextBytes
    outputPosition += nextBytes

    if inputPosition >= bytesToRead:
      # if current frame is depleted, set it to nil
      # so a new one will be received from the queue
      inputData.samples = nil

  # store the input position for the next call
  inputData.position = inputPosition


# initialize SDL audio
let audioBufferSize = uint16((1.0 / fps) * rate.float * channels.float)
var timerResolution = getPerformanceFrequency()
var audioData = AudioData(lov: l)
GC_ref(audioData)
let requested = AudioSpec(
  freq: 48000.cint,
  channels: 2.uint8,
  samples: 1024 * 64.uint16,
  format: AUDIO_S16LSB,
  callback: audioCallback,
  userdata: cast[pointer](audioData)
)

var obtained = AudioSpec()

let audioDevice = openAudioDevice(nil, 0, requested.unsafeAddr, obtained.unsafeAddr, 0)
if audioDevice == 0:
  raise newException(IOError, $getError())

let audioBufferCompensation = 40_000_000

let audioBufferDelay = 1_000_000_000 * requested.samples div requested.freq.culonglong div 2 + audioBufferCompensation.uint64

### present video frames and audio samples

var
  init = true
  run = true
  play = true
  first = true
  done = false
  evt = sdl2.defaultEvent
  fpsman: FpsManager
  queuedAudioDuration: Duration
  decodedAudioDuration: Duration
  displayedVideoDuration: Duration
  playedAudioWhenPresentedVideoDuration: Duration

fpsman.init
fpsman.setFramerate(fps)
audioDevice.pauseAudioDevice(0)

template getQueuedAudioDuration(): Duration =
  initDuration(((1_000_000_000 * audioDevice.getQueuedAudioSize().int64) div (sizeof(int16) * obtained.channels.int)) div obtained.freq)

template getPlayedAudioDuration(): Duration =
  decodedAudioDuration - getQueuedAudioDuration()

template inMilliseconds(duration: Duration): int =
  (duration.inMicroseconds div 1_000_000)

proc getAudioTime(audioData: AudioData): culonglong =
  if audioData.timerCount == 0:
    return 0
  let audioDelta = getPerformanceCounter() - audioData.timerCount
  let audioTime = audioData.timestamp + audioDelta
  if audioTime < audioBufferDelay:
    return 0
  audioTime - audioBufferDelay

while run:
  let audioTime = audioData.getAudioTime()
  var saught = false
    # prevent keyboard mashing
  while pollEvent(evt):
    const
      smallSkip = 1_000_000_000'u64
      mediumSkip = 10_000_000_000'u64
      largeSkip = 60_000_000_000'u64
    case evt.kind:
    of QuitEvent:
      run = false
      break
    of KeyDown:
      case evt.key.keysym.sym:
      of K_SPACE:
        play = not play
        audioDevice.pauseAudioDevice(play.cint)
      of K_ESCAPE, K_Q:
        run = false
        break
      of K_HOME:
        if not saught:
          saught = true
          done = false
          l.seek(0)

      of K_LEFT:
        if not saught:
          saught = true
          done = false
          l.seek(if audioTime < smallskip: 0.uint64 else: audioTime - smallSkip)
      of K_RIGHT:
        if not saught:
          saught = true
          l.seek(audioTime + smallSkip)
      of K_DOWN:
        if not saught:
          saught = true
          done = false
          l.seek(audioTime + mediumSkip)
      of K_UP:
        if not saught:
          saught = true
          done = false
          l.seek(if audioTime < mediumskip: 0.uint64 else: audioTime - mediumSkip)
      of K_PAGEDOWN:
        if not saught:
          saught = true
          done = false
          l.seek(audioTime + largeSkip)
      of K_PAGEUP:
        if not saught:
          saught = true
          done = false
          l.seek(if audioTime < largeskip: 0.uint64 else: audioTime - largeSkip)
      else:
        discard
    else:
      discard

  if 0 != renderer.clear():
    raise newException(IOError, $getError())
  if 0.SDL_Return != renderer.copy(texture, nil, nil):
    raise newException(IOError, $getError())

  block:

    var (picture, pictureTimestamp) = l.getPictureAndTimestamp()

    try:
      texture.update(picture)
    except ValueError:
      # TODO: warn or handle
      discard

    if pictureTimestamp > audioTime:
      ((pictureTimestamp - audioTime) div 1_000_000).uint32.delay

    renderer.present()
    #playedAudioWhenPresentedVideoDuration = getPlayedAudioDuration()
    #displayedVideoDuration = initDuration(packet.pictureTimestamp.int64)

destroy(renderer)
destroy(texture)
audioDevice.closeAudioDevice
GC_unref(audioData)
sdl2.quit()
