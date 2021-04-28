import os, times, locks
import sdl2, sdl2/[audio, gfx], lov/sdl2_aux
import lov, nestegg, opus

type
  
  ## Parameters to determine the application behavior
  ## These can be set by command line arguments or the environment, but are not necessarily

  ParamsObj = object

    ## the audio playback frequency, e.g. 48000
    audioFrequency: int
    
    ## the enum of playback channels, e.g. chStereo
    audioChannels: opus.Channels

    ## The number of 64-sample blocks to buffer audio with
    audioBufferSize: int

    ## The number of nanoseconds it is assumed a sample will take from being delivered
    ## to the system for playback until its sound comes out of the speaker
    audioCompensation: int

    ## The file path to play back
    path: string

    ## The verbosity setting
    verbose: bool

    ## The number of nanoseconds one tick of the hi-res timer represent, e.g. 1 on linux
    hiresCountsPerSecond: uint64

  Params = ref ParamsObj

  ## A bunch of data that is accessed by the audio callback
  ## This is used both to communicate with the audio callback (don't forget to lock)
  ## and also to pass data from one call of the callback to the next

  AudioDataObj = object

    ## lov instance to use
    lov: Lov

    ## partially used samples object
    ## outputting reads from this, advances the position, and replaces it
    ## with a fresh one when it's used up
    samples: Samples

    ## index into samples.data that is the next sample to play back
    position: int

    ## the timestamp of the first sample of the current samples object
    timestamp: culonglong

    ## the time, according to a hi-res CPU timer, when the audio callback was last called
    syncHiresCount: uint64

    ## the timestamp of the next sample to play back when the audio callback was last called
    syncSampleTime: uint64
    
    ## lock for inter-thread communication. must be aquired by the audio callback and all other threads
    ## for those parts of an AudioData that are concurrently accessed
    lock: Lock

    ## The complete delay between audio and video, including buffer and compensation
    delay: uint64

    ## The parameters object, passed on
    params: Params


  AudioData = ref AudioDataObj

proc audioCallback(audioData: pointer; output: ptr uint8; bytesToWrite: cint) {.cdecl.} =
  ## Audio callback function
  ## 
  ## Feeds chunks of data to the SDL sound output as demanded
  ## Gets the data from decoded chunks
  ## Keeps a partially used chunk around and gets a new one when it's used up
  ##
  ## Doubles as a timing source for audio sync, using a hi-res timer to note when
  ## the callback was called, and also notes what the play time of the next sample
  ## to play was, defining a sync point between scheduled time from the packets,
  ## and playback time from the CPU
  let
    hiresCount = getPerformanceCounter() # measure time for this audio chunk immediately

  var
    # cast data to useful structure
    audioData = cast[AudioData](audioData)

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
  if audioData.samples != nil:
    bytesToRead = audioData.samples.bytes
    input = cast[ptr UncheckedArray[byte]](audioData.samples.data)
    inputPosition = audioData.position

  # flag to execute a block of code on the first iteration,
  # but not at the beginning of the loop
  var firstIteration = true

  # keep going until bytesToWrite samples were written
  while outputPosition < bytesToWrite:
    var timestamp: uint64

    # get another chunk of decoded samples from the queue
    if audioData.samples == nil:
      let queueSize = audioData.lov.samples[].peek()
      if queueSize == 0:
        # Emit silence if there is a buffer underrun
        # this only works because this is the only audio thread consuming audio frames
        # it should really be using tryRecv, but that failed a lot even with
        # a populated queue
        let nextBytes = bytesToWrite - outputPosition
        if audioData.params.verbose:
          stderr.write "frames available: ", $audioData.lov.samples[].peek(), "\n"
          stderr.write "audio buffer underrun, skipping ", nextBytes div (sizeof(int16) * chStereo.int), " frames\n"
        zeroMem(output[outputPosition].addr, nextBytes)
        break
      (audioData.samples, audioData.timestamp) = audioData.lov.samples[].recv()
      bytesToRead = audioData.samples.bytes
      input = cast[ptr UncheckedArray[byte]](audioData.samples.data)
      inputPosition = 0

    if firstIteration:
      firstIteration = false
      audioData.syncHiresCount = hiresCount 
      audioData.syncSampleTime = audioData.timestamp + uint64(inputPosition * 1_000_000_000 div audioData.params.audioFrequency div (chStereo.int * sizeof(int16)))

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
      audioData.samples = nil

  # store the input position for the next call
  audioData.position = inputPosition

proc getAudioTime(audioData: AudioData): culonglong =
  ##
  ## A kludge to guess the timestamp of the sample currently played back
  ## by the speakers.
  ##
  ## Using a high resolution timer, the time passed since the last call
  ## of the audio callback is determined. This is added to the timestamp
  ## of the sample up for playback at that time, along with a heuristic
  ## correction value to account for the time the system takes to play back
  ## the sample.
  ##
  ## Oddly enough, there seems to be no better way to do this.
  ##
  if audioData.syncHiresCount == 0:
    return 0
  let timeSinceSync = (getPerformanceCounter() - audioData.syncHiresCount) * 1_000_000_000 div audioData.params.hiresCountsPerSecond
  let audioTime = audioData.syncSampleTime + timeSinceSync
  if audioTime < audioData.delay:
    return 0
  audioTime - audioData.delay

#
# Start of application code
#

## init configuration from command line params

var params = Params()

# TODO: implement proper parsing
assert paramCount() == 1, "please specify file to play on command line"

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
  params.path = paramStr(1)

params.hiresCountsPerSecond = getPerformanceFrequency()
params.verbose = true

params.audioFrequency = 48000
params.audioChannels = chStereo
params.audioCompensation = 80_000_000

var l = newLov(params.path, 20)

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

# keep aspect ratio and handle window resizes
if 0 != renderer.setLogicalSize(width.cint, height.cint):
  raise newException(IOError, $getError())

renderer.setDrawColor(0, 0, 0)

let texture = createTexture(renderer, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, width.cint, height.cint)
  # create texture, the video will render to this 

var audioData = AudioData(
  lov: l,
  delay: uint64(1_000_000_000 * params.audioBufferSize div params.audioFrequency div chStereo.int + params.audioCompensation),
  params: params,
)

# initialize SDL audio
let audioBufferSize = uint16((1.0 / fps) * rate.float * channels.float)
let requested = AudioSpec(
  freq: params.audioFrequency.cint,
  channels: params.audioChannels.uint8,
  samples: params.audioBufferSize.uint16 * 64.uint16,
  format: AUDIO_S16LSB,
  callback: audioCallback,
  userdata: cast[pointer](audioData)
)
var obtained = AudioSpec()

let audioDevice = openAudioDevice(nil, 0, requested.unsafeAddr, obtained.unsafeAddr, 0)
if audioDevice == 0:
  raise newException(IOError, $getError())

### present video frames and audio samples

var
  run = true
  play = true
  evt = sdl2.defaultEvent
  fpsman: FpsManager
  queuedAudioDuration: Duration
  decodedAudioDuration: Duration
  displayedVideoDuration: Duration
  playedAudioWhenPresentedVideoDuration: Duration

template doSeek(seekPosition) =
  if not saught:
    audioDevice.pauseAudioDevice(1)
    saught = true
    audioData.samples = nil
    audioData.syncHiresCount = 0
    audioData.syncSampleTime = 0
    l.seek(seekPosition)
    audioDevice.pauseAudioDevice(0)
    continue

audioDevice.pauseAudioDevice(0)

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
        doSeek(0)
      of K_LEFT:
        doSeek(if audioTime < smallskip: 0.uint64 else: audioTime - smallSkip)
      of K_RIGHT:
        doSeek(audioTime + smallSkip)
      of K_DOWN:
        doSeek(audioTime + mediumSkip)
      of K_UP:
        doSeek(if audioTime < mediumskip: 0.uint64 else: audioTime - mediumSkip)
      of K_PAGEDOWN:
        doSeek(audioTime + largeSkip)
      of K_PAGEUP:
        doSeek(if audioTime < largeskip: 0.uint64 else: audioTime - largeSkip)
      of K_1:
        doSeek(10_000_000_000'u64)
      of K_2:
        doSeek(20_000_000_000'u64)
      of K_3:
        doSeek(30_000_000_000'u64)
      of K_4:
        doSeek(40_000_000_000'u64)
      of K_5:
        doSeek(50_000_000_000'u64)
      else:
        discard
    else:
      discard

  if 0 != renderer.clear():
    raise newException(IOError, $getError())
  if 0.SDL_Return != renderer.copy(texture, nil, nil):
    raise newException(IOError, $getError())

  if audioTime > 0:
    var (picture, pictureTimestamp) = l.getPictureAndTimestamp()

    try:
      texture.update(picture)
    except ValueError:
      # TODO: warn or handle
      discard

    if pictureTimestamp > audioTime:
      ((pictureTimestamp - audioTime) div 1_000_000).uint32.delay
    else:
      discard

  else:
    5.delay

  renderer.present()

destroy(renderer)
destroy(texture)
audioDevice.closeAudioDevice
sdl2.quit()
