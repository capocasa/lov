import dav1d, nestegg, opus

type
  LovObj* = object
    demuxer*: Demuxer
    opusDecoder*: opus.Decoder
    av1Decoder*: dav1d.Decoder
    picture*: ptr Channel[(Picture, culonglong)]
    samples*: ptr Channel[(Samples, culonglong)]
    control*: ptr Channel[Control]
      # this must be a pointer to pass it to
      # the demuxer channel- the rest of this object
      # is passed via that channel so can be
      # garbage collected
      # consider this a hack
    decmux: Thread[ptr Channel[Control]]
  Lov* = ref LovObj
  ControlKind = enum
    cInit
    cSeek
  Control = object
    case kind: ControlKind
    of cInit:
      decmuxInit: DecmuxInit
    of cSeek:
      timestamp: uint64
  DecmuxInit* = tuple[
    demuxer: Demuxer,
    av1Decoder: dav1d.Decoder,
    opusDecoder: opus.Decoder,
    picture: ptr Channel[(Picture, culonglong)],
    samples: ptr Channel[(Samples, culonglong)],
    control: ptr Channel[Control]
  ]

export Picture, Samples

const
  defaultQueueSize = 30

template doSeek() =
  ## Utility template for decmux, handles a seek message
  # flush channel buffer
  while decmuxInit.picture[].peek() > 0:
    discard decmuxInit.picture[].recv()
  while decmuxInit.samples[].peek() > 0:
    discard decmuxInit.samples[].recv()
  while true:
    # empty video decoder
    try:
      discard decmuxInit.av1Decoder.getPicture()
    except BufferError:
      break
  decmuxInit.av1Decoder.flush() # reset video decoder state
  decmuxInit.demuxer.seek(control.timestamp)
  
  skipping = true
  skipUntil = control.timestamp

proc decmux*(control: ptr Channel[Control]) {.thread} =
  ## The demuxer-decoder thread- opens up a file, demuxes it into its packets,
  ## decodes those appropriately, and sends the packet data to the
  ## presenter thread via a channel so it can be shown. Tells the presenter
  ## thread to quit when it's done.
  
  var c = control[].recv()
  var decmuxInit: DecmuxInit
  case c.kind:
  of cInit:
    decmuxInit = c.decmuxInit
  else:
    raise newException(AssertionDefect, "Must init demuxer thread before sending other messages")
  
  var skipping = false
  var skipUntil:culonglong
  while true:
    block restart:
      for packet in decmuxInit.demuxer:

        let (received, control) = decmuxInit.control[].tryRecv
          ## Check if a seek was requested and handle it
        if received:
          case control.kind:
          of cSeek:
            doSeek()
            break restart

          of cInit:
            raise newException(Defect, "already initialized")

        # turn of frame skipping if far enough
        if skipping:
          if packet.timestamp >= skipUntil:
            skipping = false

        case packet.track.kind:
        of tkAudio:
          case packet.track.audioCodec:
          of acOpus:
            for chunk in packet:
              let samples = decmuxInit.opusDecoder.decode(chunk.data, chunk.len)
              if not skipping:
                decmuxInit.samples[].send((samples, packet.timestamp))
          else:
            raise newException(ValueError, "codec not supported: " & $packet.track.audioCodec)
        of tkVideo:
          case packet.track.videoCodec:
          of vcAv1:
            for chunk in packet:
              try:
                decmuxInit.av1Decoder.send(chunk.data, chunk.len)
              except BufferError:
                # TODO: permit frame/tile threads
                raise getCurrentException()

              # video decode and delay for timing source
              try:
                var picture = decmuxInit.av1Decoder.getPicture()
                if not skipping:
                  decmuxInit.picture[].send((picture, packet.timestamp))
              except BufferError:
                # TODO: permit frame/tile threads 
                raise getCurrentException()

          else:
            # TODO: handle unknown packet codec
            discard
        else:
          # TODO: handle packet
          discard

      # we now decoded everything in the file

      let control = decmuxInit.control[].recv()
        # Wait for a seek, rather than checking for a seek with tryRecv,
        # because there is no demuxing so nothing else to do while we wait
      case control.kind:
      of cSeek:
        doSeek()
        break restart
      of cInit:
        raise newException(Defect, "already initialized")


proc cleanup*(lov: Lov) =
  deallocShared(lov.control)
  deallocShared(lov.picture)
  deallocShared(lov.samples)

proc newLov*(demuxer: Demuxer, queueSize = defaultQueueSize): Lov =
  new(result, cleanup)
  result.demuxer = demuxer
  result.av1Decoder = dav1d.newDecoder()
  result.opusDecoder = opus.newDecoder(sr48k, chStereo)
    # opus is supposed to decode at 48k stereo and then downsample and/or downmix

  result.control = cast[ptr Channel[Control]](allocShared0(sizeof(Channel[Control])))
  result.picture = cast[ptr Channel[(Picture, culonglong)]](allocShared0(sizeof(Channel[(Picture, culonglong)])))
  result.samples = cast[ptr Channel[(Samples, culonglong)]](allocShared0(sizeof(Channel[(Samples, culonglong)])))
    # this gets cleaned up with function above
  result.control[].open(1)
  result.picture[].open(queueSize)
  result.samples[].open(queueSize * chStereo.int)
    # todo: buffer control messages and drop the right ones
  result.decmux.createThread(decmux, result.control)

  result.control[].send(Control(kind: cInit, decmuxInit: (
    demuxer: result.demuxer,
    av1Decoder: result.av1Decoder,
    opusDecoder: result.opusDecoder,
    picture: result.picture,
    samples: result.samples,
    control: result.control
  )))

template newLov*(file: File, queueSize = defaultQueueSize): Lov =
  newLov(newDemuxer(file), queueSize)

template newLov*(filename: string, queueSize = defaultQueueSize): Lov =
  newLov(newDemuxer(filename.open), queueSize)

proc getPictureAndTimestamp*(lov: Lov): (Picture, culonglong) =
  lov.picture[].recv()

proc getSamplesAndTimestamp*(lov: Lov): (Samples, culonglong) =
  lov.samples[].recv()

proc seek*(lov: Lov, timestamp: uint64) =
  ## Instruct the demuxer-decoder to change its timestamp to the specified time
  ## in nanoseconds.
  lov.control[].send(Control(kind: cSeek, timestamp: timestamp))
