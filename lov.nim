
import os
import sdl2, sdl2/[audio]
import dav1d, nestegg, opus

import lov/[dump, sdl2_aux]

const
  width = 720
  height = 480
  fps = 25
  rate = 48000
  channels = chStereo
  audioBufferSize = uint16((1.0 / fps) * rate.float * channels.float)
    # samples to fill one video frame
  queueSize = 5

type
  MessageKind = enum
    ## Message types that can be sent to the presenter
    ## thread by the demuxer-decoder
    msgDone, msgVideo, msgAudio
  Message = object
    ## Message objects that can be sent to the presnter
    ## thread by the demuxer-decoder
    ## Can contain a decoded video frame, some decoded audio
    ## samples, or nothing, if it's time to quit
    case kind: MessageKind
    of msgDone:
      discard
    of msgVideo:
      picture: Picture
    of msgAudio:
      samples: Samples

var
  channel: Channel[Message]
    ## A module-scope channel used by the demuxer-decoder to
    ## communicate with the presenter thread

proc demuc(filename: string) {.thread} =
  ## The demuxer-decoder- opens up a file, demuxes it into its packets,
  ## decodes those appropriately, and sends the decoded data to the
  ## presenter thread via a channel so it can be shown. Tells the presenter
  ## thread to quit when it's done.

  var file = filename.open
  var av1Decoder = dav1d.newDecoder()
  var opusDecoder = opus.newDecoder(sr48k, chStereo)
  var demuxer = newDemuxer(file)

  for packet in demuxer:

    case packet.track.kind:
    of tkAudio:
      case packet.track.audioCodec:
      of acOpus:
        for chunk in packet:
          var msg = Message(kind: msgAudio)
          msg.samples = opusDecoder.decode(chunk.data, chunk.len)
          channel.send(msg)
      else:
        raise newException(ValueError, "codec $# not supported" % $packet.track.audioCodec)
    of tkVideo:
      case packet.track.videoCodec:
      of vcAv1:
        for chunk in packet:
          try:
            av1Decoder.send(chunk.data, chunk.len)
          except BufferError:
            # TODO: handle
            raise getCurrentException()

          # video decode and delay for timing source
          var msg = Message(kind: msgVideo)
          try:
            msg.picture = av1Decoder.getPicture()
          except BufferError:
            # TODO: handle
            raise getCurrentException()
          
          channel.send(msg)
      else:
        # TODO: handle unknown packet codec
        discard
    else:
      # TODO: handle packet
      discard

  channel.send(Message(kind: msgDone))
  file.close

proc present() {.thread} =
  ## A thread procedure that waits for messages from the demuxer that contain either
  ## decoded data to display or a quit message.
  ## If no data comes, then the presenter does nothing, playing back silence or freezing
  ## at the last decoded frame.

  # initialize all needed SDL objects
  discard sdl2.init(INIT_EVERYTHING)
  var window = createWindow("lov", 100, 100, 100 + width, 1 + height, SDL_WINDOW_SHOWN)
  if window == nil:
    raise newException(IOError, $getError())

  var renderer = createRenderer(window, -1, RendererAccelerated or RendererPresentVsync)
  if renderer == nil:
    raise newException(IOError, $getError())

  var texture = createTexture(renderer, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, width, height)

  # initialize the rendering texture
  discard renderer.clear()
  discard renderer.copy(texture, nil, nil)
  renderer.present()

  # initialize audio
  let requested = AudioSpec(freq: rate, channels: channels.uint8, samples: audioBufferSize, format: AUDIO_S16LSB)
  var obtained = AudioSpec()
  var audioDevice = openAudioDevice(nil, 0, requested.unsafeAddr, obtained.unsafeAddr, 0)
  audioDevice.pauseAudioDevice(0)

  # initialize timing system
  let perfsPerSecond = getPerformanceFrequency()
    # A "perf" is a system-specific unit of time returned by the
    # SDl cross-platform high resolution timer "getPerformanceCounter"
  let perfsPerFrame = perfsPerSecond div fps.uint64

  var remainingPerfsInFrame: uint64
  var remainingMsInFrame: uint64
  var currentTimeInPerfs: uint64
  var nextFrameInPerfs = getPerformanceCounter() + perfsPerFrame

  proc update(texture: TexturePtr, pic: Picture) =
    ## A helper function to streamingly update an SDL texture
    ## with a frame in dav1d's output format
    let r = updateYUVTexture(texture, nil,
      cast[ptr byte](pic.raw.data[0]), pic.raw.stride[0].cint, # Y
      cast[ptr byte](pic.raw.data[1]), pic.raw.stride[1].cint, # U
      cast[ptr byte](pic.raw.data[2]), pic.raw.stride[1].cint  # V
    )
    if r != 0.SDL_return:
      raise newException(ValueError, "yuv update failed, " % $getError())

  # everything is initialized, let's start waiting for messages with
  # packets from the demuxer, and present them
  while true:
    # wait for a message containing a demuxed packet, or a flag
    # that it's time to quit
    let msg = channel.recv()

    case msg.kind:
    of msgDone:
      # demuxer is done, so we're done too
      # no buffer needs to be drained, channel buffers transparently
      delay 500
      destroy(renderer)
      destroy(texture)
      audioDevice.closeAudioDevice
      sdl2.quit()
      break

    of msgVideo:
      # a video frame arrives, display it and wait
      # until it's the right time- then show it
      texture.update(msg.picture)
      discard renderer.clear()
      discard renderer.copy(texture, nil, nil)
      currentTimeInPerfs = getPerformanceCounter()
      if nextFrameInPerfs < currentTimeInPerfs:
        # TODO: handle frame slowdown
        remainingPerfsInFrame = 0
      else:
        remainingPerfsInFrame = nextFrameInPerfs - currentTimeInPerfs
      remainingMsInFrame = (remainingPerfsInFrame * 1000) div perfsPerSecond
        # calculate 
      delay remainingMsInFrame.uint32
        # actually wait
      renderer.present()
        # show  the frame
      nextFrameInPerfs += perfsPerFrame
        # make a note when it's time for the next frame

    of msgAudio:
      # an audio packet has arrived. queue it, that's all
      # TODO: handle potential drift between audio clock
      # and wherever getPerformanceCounter gets is timing
      # for very long video
      let r = audioDevice.queueAudio(msg.samples.data, msg.samples.bytes.uint32)
      if r != 0:
        raise newException(IOError, $getError())

if isMainModule:

  assert paramCount() == 1, "please specify file to play on command line"
  case paramStr(1):
  of "--help":
    echo "Usage: lov [video.webm]"
    echo ""
    echo "video.webm must be an av1/opus-s16/webm video file"
  else:
    let filename = paramStr(1)

    channel.open(queueSize)
      # open a channel to communicate with a presentation thread

    var presenter:Thread[void]
    presenter.createThread(present)
      # create a presentation thread that will wait for data to 
      # show via SDL

    var demucer:Thread[string]
    demucer.createThread(demuc, filename)
      # start demuxing and decoding- the demuxer-decoder will tell the presenter what to show via the channel

    demucer.joinThread()

    channel.close()

