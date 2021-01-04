
import sdl2, sdl2/[audio]
import dav1d, nestegg, opus
import dump, sdl2_aux

const
  queueSize = 5

type
  IOObj* = object
    demuxer*: Demuxer
    opusDecoder*: opus.Decoder
    av1Decoder*: dav1d.Decoder
    audioDevice*: AudioDeviceID
    texture*: TexturePtr
    renderer*: RendererPtr
  IO* = ptr IOObj
  MessageKind* = enum
    msgAudio
    msgVideo
    msgInit
    msgDone
  Message = object
    ## Message and other data objects that can be sent to the presenter
    ## thread by the demuxer-decoder
    ## Can contain a message video frame, some message audio
    ## samples, init data, or nothing if it's time to quit
    case kind: MessageKind
    of msgVideo:
      picture: Picture
        ## Message data is a dav1d format YUV picture
    of msgAudio:
      samples: Samples
        ## Message data is PCM audio samples
    of msgInit:
      io: IO
    of msgDone:
      discard
  PlayerObj* = object
    ## High level playback object, takes a webm file to read from
    ## and a texture and audio device to write to
    decmux: Thread[ptr Channel[Message]]
    present: Thread[ptr Channel[Message]]
    channel: Channel[Message]
    channel2: Channel[Message]
    io: IO
  Player* = ref PlayerObj

proc decmux(channel: ptr Channel[Message]) {.thread} =
  ## The demuxer-decoder thread- opens up a file, demuxes it into its packets,
  ## decodes those appropriately, and sends the message data to the
  ## presenter thread via a channel so it can be shown. Tells the presenter
  ## thread to quit when it's done.
  
  echo "decmux"

  var initMsg = channel[].recv()
  var io = initMsg.io
  echo $io.audioDevice
  echo "decmux init"

  channel[].send(initMsg)

  for packet in io.demuxer:

    case packet.track.kind:
    of tkAudio:
      case packet.track.audioCodec:
      of acOpus:
        for chunk in packet:
          var message = Message(kind: msgAudio)
          message.samples = io.opusDecoder.decode(chunk.data, chunk.len)
          channel[].send(message)
          echo "send audio"
      else:
        raise newException(ValueError, "codec $# not supported" % $packet.track.audioCodec)
    of tkVideo:
      case packet.track.videoCodec:
      of vcAv1:
        for chunk in packet:
          try:
            io.av1Decoder.send(chunk.data, chunk.len)
          except BufferError:
            # TODO: handle
            raise getCurrentException()

          # video decode and delay for timing source
          var message = Message(kind: msgVideo)
          try:
            message.picture = io.av1Decoder.getPicture()
          except BufferError:
            # TODO: handle
            raise getCurrentException()
          
          echo "send video"
          channel[].send(message)
      else:
        # TODO: handle unknown packet codec
        discard
    else:
      # TODO: handle packet
      discard

  channel[].send(Message(kind: msgDone))

proc present(channel: ptr Channel[Message]) {.thread} =
  ## A thread procedure that waits for messages from the demuxer that contain either
  ## message data to display or a quit message.
  ## If no data comes, then the presenter does nothing, playing back silence or freezing
  ## at the last message frame.
  
  echo "present"

  # initialize all needed SDL objects
  
  var
    io: IO
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
    let message = channel[].recv()

    case message.kind:

    of msgVideo:
      # a video frame arrives, display it and wait
      # until it's the right time- then show it
      echo "receive video"
      io.texture.update(message.picture)
      discard io.renderer.clear()
      discard io.renderer.copy(io.texture, nil, nil)
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
      io.renderer.present()
        # show  the frame
      nextFrameInPerfs += perfsPerFrame
        # make a note when it's time for the next frame

    of msgAudio:
      # an audio packet has arrived. queue it, that's all
      # TODO: handle potential drift between audio clock
      # and wherever getPerformanceCounter gets is timing
      # for very long video
      echo "receive audio"
      let r = io.audioDevice.queueAudio(message.samples.data, message.samples.bytes.uint32)
      if r != 0:
        raise newException(IOError, $getError())
    of msgInit:
      echo "receive init"
      io = message.io
      echo $io.audioDevice

      discard io.renderer.clear()
      discard io.renderer.copy(io.texture, nil, nil)
      io.renderer.present()
    of msgDone:
      echo "receive done"
      break

proc cleanup*(player: Player) =
  #player.channel[].close()
  #player.channel.deallocShared
  discard

proc newPlayer*(demuxer: Demuxer, window: WindowPtr, texture: TexturePtr, audioDevice: AudioDeviceID): Player =

  #result = cast[Player](allocShared(sizeof(PlayerObj)))
  new(result, cleanup)

  result.io = cast[IO](allocShared0(sizeof(IOObj)))

  # store components
  result.io.demuxer = demuxer
  result.io.texture = texture
  result.io.audioDevice = audioDevice

  echo "new A: ", $audioDevice
  echo "new IO.A: ", $result.io.audioDevice

  # initialize components
  result.io.av1Decoder = dav1d.newDecoder()
    # video decoder (no destruction required)
  result.io.opusDecoder = opus.newDecoder(sr48k, chStereo)
    # audio decoder (no destruction required)

  result.channel.open(queueSize)

  result.decmux.createThread(decmux, result.channel.addr)
    # start demuxing and decoding- the demuxer-decoder will tell the presenter what to show via the channel
  result.present.createThread(present, result.channel.addr)

  result.channel.send(Message(kind: msgInit, io: result.io))

  result.present.joinThread()

#proc play*(player: Player) =
#  discard

