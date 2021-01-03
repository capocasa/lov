
import sdl2, sdl2/[audio]
import dav1d, nestegg, opus
import dump, sdl2_aux

const
  queueSize = 5

type
  DecodedKind* = enum
    dkAudio
    dkVideo
  Decoded = object
    ## Decoded data objects that can be sent to the presnter
    ## thread by the demuxer-decoder
    ## Can contain a decoded video frame, some decoded audio
    ## samples, or nothing, if it's time to quit
    case kind: DecodedKind 
    of dkVideo:
      picture: Picture
        ## Decoded data is a dav1d format YUV picture
    of dkAudio:
      samples: Samples
        ## Decoded data is PCM audio samples
  PlayerObj* = object
    ## High level playback object, takes a webm file to read from
    ## and a texture and audio device to write to
    demuxer*: Demuxer
    opusDecoder*: opus.Decoder
    av1Decoder*: dav1d.Decoder
    renderer*: RendererPtr
    audioDevice*: AudioDeviceID
    texture*: TexturePtr
    channel: ptr Channel[Decoded]
      ## A channel used by the demuxer-decoder thread to
      ## send packets of decoded data to the presenter thread
    decmux: Thread[Player]
    present: Thread[Player]
  Player* = ref PlayerObj

proc decmux(player: Player) {.thread} =
  ## The demuxer-decoder thread- opens up a file, demuxes it into its packets,
  ## decodes those appropriately, and sends the decoded data to the
  ## presenter thread via a channel so it can be shown. Tells the presenter
  ## thread to quit when it's done.

  for packet in player.demuxer:

    case packet.track.kind:
    of tkAudio:
      case packet.track.audioCodec:
      of acOpus:
        for chunk in packet:
          var decoded = Decoded(kind: dkAudio)
          decoded.samples = player.opusDecoder.decode(chunk.data, chunk.len)
          player.channel[].send(decoded)
      else:
        raise newException(ValueError, "codec $# not supported" % $packet.track.audioCodec)
    of tkVideo:
      case packet.track.videoCodec:
      of vcAv1:
        for chunk in packet:
          try:
            player.av1Decoder.send(chunk.data, chunk.len)
          except BufferError:
            # TODO: handle
            raise getCurrentException()

          # video decode and delay for timing source
          var decoded = Decoded(kind: dkVideo)
          try:
            decoded.picture = player.av1Decoder.getPicture()
          except BufferError:
            # TODO: handle
            raise getCurrentException()
          
          player.channel[].send(decoded)
      else:
        # TODO: handle unknown packet codec
        discard
    else:
      # TODO: handle packet
      discard

proc present(player: Player) {.thread} =
  ## A thread procedure that waits for messages from the demuxer that contain either
  ## decoded data to display or a quit message.
  ## If no data comes, then the presenter does nothing, playing back silence or freezing
  ## at the last decoded frame.

  # initialize all needed SDL objects
  discard sdl2.init(INIT_EVERYTHING)
  var
    texture = player.texture
    renderer = player.renderer
    channel = player.channel

    perfsPerSecond: uint64
    perfsPerFrame: uint64
    remainingPerfsInFrame: uint64
    remainingMsInFrame: uint64
    currentTimeInPerfs: uint64
    nextFrameInPerfs: uint64
    fps = 25

  proc update(texture: TexturePtr, pic: Picture) =
    ## A helper function to streamingly update an SDL texture
    ## with a frame in dav1d's output format
    echo "update"
    let r = updateYUVTexture(texture, nil,
      cast[ptr byte](pic.raw.data[0]), pic.raw.stride[0].cint, # Y
      cast[ptr byte](pic.raw.data[1]), pic.raw.stride[1].cint, # U
      cast[ptr byte](pic.raw.data[2]), pic.raw.stride[1].cint  # V
    )
    if r != 0.SDL_return:
      raise newException(ValueError, "yuv update failed, " % $getError())

  # initialize timing system
  perfsPerSecond = getPerformanceFrequency()
    # A "perf" is a system-specific unit of time returned by the
    # SDl cross-platform high resolution timer "getPerformanceCounter"
  perfsPerFrame = perfsPerSecond div fps.uint64
  nextFrameInPerfs = getPerformanceCounter() + perfsPerFrame

  # everything is initialized, let's start waiting for messages with
  # packets from the demuxer, and present them
  while true:
    # wait for a message containing a demuxed packet
    let decoded = player.channel[].recv()

    case decoded.kind:

    of dkVideo:
      echo "video frame"
      # a video frame arrives, display it and wait
      # until it's the right time- then show it
      texture.update(decoded.picture)
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

    of dkAudio:
      echo "audio frame"
      # an audio packet has arrived. queue it, that's all
      # TODO: handle potential drift between audio clock
      # and wherever getPerformanceCounter gets is timing
      # for very long video
      let r = player.audioDevice.queueAudio(decoded.samples.data, decoded.samples.bytes.uint32)
      if r != 0:
        raise newException(IOError, $getError())

proc cleanup*(player: Player) =
  player.channel[].close()
  player.channel.deallocShared

proc newPlayer*(demuxer: Demuxer, texture: TexturePtr, audioDevice: AudioDeviceID): Player =
  new(result, cleanup)
  result.channel = cast[ptr Channel[Decoded]](allocShared0(sizeof(Channel[Decoded])))

  # store components
  result.demuxer = demuxer
  result.texture = texture
  result.audioDevice = audioDevice

  # initialize components
  result.av1Decoder = dav1d.newDecoder()
    # video decoder (no destruction required)
  result.opusDecoder = opus.newDecoder(sr48k, chStereo)
    # audio decoder (no destruction required)
  result.channel[].open(queueSize)
    # open a channel to communicate with a presentation thread

  result.decmux.createThread(decmux, result)
    # start demuxing and decoding- the demuxer-decoder will tell the presenter what to show via the channel

  result.present.createThread(present, result)
  result.present.joinThread()

#proc play*(player: Player) =
#  discard

