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
    queueSizeVideo*: int
    queueSizeAudio*: int
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
  defaultQueueSize = 10

template doSeek() =
  ## Utility template for decmux, handles a seek message
  # flush channel buffer
  echo "clearing picture queue"
  while decmuxInit.picture[].peek() > 0:
    discard decmuxInit.picture[].recv()
  echo "clearing samples queue"
  while decmuxInit.samples[].peek() > 0:
    discard decmuxInit.samples[].recv()
  echo "clearing video decoder"
  while true:
    # empty video decoder
    try:
      discard decmuxInit.av1Decoder.getPicture()
    except BufferError:
      break
  echo "flushing video decoder"
  decmuxInit.av1Decoder.flush() # reset video decoder state
  echo "performing demuxer seek to ", $control.timestamp
  decmuxInit.demuxer.seek(control.timestamp)
  
  # a seek is performed by nim-nestegg on the video track.
  # after the seek, the next video packet will be the correct one,
  # but a number of audio packets will be earlier and need to be
  # skipped
  skipAudio = true
  skipAudioUntil = control.timestamp

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
  
  var skipAudio = false
  var skipAudioUntil:culonglong
  while true:
    block restart:
      echo "now restarting"
      for packet in decmuxInit.demuxer:
        echo "incoming packet at ", $packet.timestamp

        let (received, control) = decmuxInit.control[].tryRecv
          ## Check if a seek was requested and handle it
        if received:
          case control.kind:
          of cSeek:
            echo "incoming seek to ", $control.timestamp
            doSeek()
            break restart

          of cInit:
            raise newException(Defect, "already initialized")

        case packet.track.kind:
        of tkAudio:
          
          # if audio packets are no longer earlier than the skip, stop skipping and 
          # start using them
          if skipAudio:
            if packet.timestamp >= skipAudioUntil:
              skipAudio = false

          case packet.track.audioCodec:
          of acOpus:
            for chunk in packet:
              if skipAudio:
                echo "skipAudio audio packet at ", $packet.timestamp
              if not skipAudio:
                let samples = decmuxInit.opusDecoder.decode(chunk.data, chunk.len)
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
                if skipAudio:
                  echo "skipAudio audio packet at ", $packet.timestamp
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

      echo "file complete, now waiting for seek"
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

  result.queueSizeVideo = queueSize
  result.queueSizeAudio = queueSize * chStereo.int
  result.control = cast[ptr Channel[Control]](allocShared0(sizeof(Channel[Control])))
  result.picture = cast[ptr Channel[(Picture, culonglong)]](allocShared0(sizeof(Channel[(Picture, culonglong)])))
  result.samples = cast[ptr Channel[(Samples, culonglong)]](allocShared0(sizeof(Channel[(Samples, culonglong)])))
    # this gets cleaned up with function above
  result.control[].open(1)
  result.picture[].open(result.queueSizeVideo)
  result.samples[].open(result.queueSizeAudio)
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


