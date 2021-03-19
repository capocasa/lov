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
  l = newLov(paramStr(1), 100)

### init SDL
if 0.SDL_return < sdl2.init(INIT_EVERYTHING):
  raise newException(IOError, $getError())

var
  fps = l.demuxer.firstVideo.fps
  width = l.demuxer.firstVideo.videoParams.width
  height = l.demuxer.firstVideo.videoParams.height
  rate = l.demuxer.firstAudio.audioParams.rate
  channels = l.demuxer.firstAudio.audioParams.channels
#[
  fps = 25.0
  width = 720
  height = 480
  rate = 48000
  channels = 2
]#

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
      var r = inputData.lov.samples[].tryRecv()
      if not r.dataAvailable:
        zeroMem(output[outputPosition].addr, bytesToWrite - outputPosition)
        break
      (inputData.samples, inputData.timestamp) = r.msg

      bytesToRead = inputData.samples.bytes
      input = cast[ptr UncheckedArray[byte]](inputData.samples.data)
      inputPosition = 0
      inputData.timerCount = getPerformanceCounter()

    # write as many samples as can without loading another chunk of decoded samples,
    # and without overflowing the output buffer
    let nextBytes = min(bytesToRead - inputPosition, bytesToWrite - outputPosition)

    # echo "copy outputPosition:", $outputPosition, " bytesToWrite: ", $bytesToWrite, " inputPosition:", $inputPosition, " bytesToRead: ", $bytesToRead, " nextBytes: " & $nextBytes & " chunks: ", $inputData.lov.samples[].peek()
    
    # do the actual writing. note taking the address from an array access is
    # a convenient alternative to pointer arithmetic that is as safe as is possible
    # for C-interoperable code
    copyMem(output[outputPosition].addr, input[inputPosition].addr, nextBytes)
    inputPosition += nextBytes
    outputPosition += nextBytes

    if inputPosition >= bytesToRead:
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

# let audioBufferDelay = 1_000_000_000 * requested.samples div requested.freq.culonglong div 2

let audioBufferDelay = 120_000_000.culonglong

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

echo "timer res ", $timerResolution

while run:
  var saught = false
    # prevent keyboard mashing
  while pollEvent(evt):
    const
      smallSkip = 1_000_000
      mediumSkip = 10_000_000
      largeSkip = 60_000_000
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
#[
      of K_LEFT:
        if not saught:
          saught = true
          done = false
          l.seek(if videoTimestamp < smallskip: 0.uint64 else: videoTimestamp - smallSkip)
      of K_RIGHT:
        if not saught:
          saught = true
          l.seek(videoTimestamp + smallSkip)
      of K_DOWN:
        if not saught:
          saught = true
          done = false
          l.seek(videoTimestamp + mediumSkip)
      of K_UP:
        if not saught:
          saught = true
          done = false
          l.seek(if videoTimestamp < mediumskip: 0.uint64 else: videoTimestamp - mediumSkip)
      of K_PAGEDOWN:
        if not saught:
          saught = true
          done = false
          l.seek(videoTimestamp + largeSkip)
      of K_PAGEUP:
        if not saught:
          saught = true
          done = false
          l.seek(if videoTimestamp < largeskip: 0.uint64 else: videoTimestamp - largeSkip)
]#
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

    # echo "picture timestamp ", $pictureTimestamp, " audioTime ", $audioTime 

    try:
      texture.update(picture)
    except ValueError:
      # TODO: warn or handle
      discard

    #[
    let currentVideoDuration = initDuration(pictureTimestamp.int64)
    echo "getQueuedAudioSize: ", $audioDevice.getQueuedAudioSize()
    echo "getQueuedAudioDuration: ", $getQueuedAudioDuration()
    echo "decodedAudioDuration: ", $decodedAudioDuration
    echo "currentVideoDuration: ", $currentVideoDuration
    echo "displayedVideoDuration: ", $displayedVideoDuration
    echo "getPlayedAudioDuration(): ", $getPlayedAudioDuration()
    echo "playedAudioWhenPresentedVideoDuration: ", $playedAudioWhenPresentedVideoDuration
    #echo "calculated delay: ", $(currentVideoDuration - displayedVideoDuration - (getPlayedAudioDuration() - playedAudioWhenPresentedVideoDuration))
    echo ""
    ]#

    let audioTime = audioData.getAudioTime()

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
