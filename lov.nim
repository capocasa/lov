
import os, strutils
import dav1d, nestegg, opus

type
  PacketKind* = enum
    pktAudio
    pktVideo
    pktDone
  Packet* = object
    ## Packet and other data objects that can be sent to the presenter
    ## thread by the demuxer-decoder
    ## Can contain a packet video frame, some packet audio
    ## samples, init data, or nothing if it's time to quit
    case kind*: PacketKind
    of pktVideo:
      picture*: Picture
        ## Packet data is a dav1d format YUV picture
    of pktAudio:
      samples*: Samples
        ## Packet data is PCM audio samples
    of pktDone:
      discard
    timestamp*: uint64
  LovObj* = object
    demuxer*: Demuxer
    opusDecoder*: opus.Decoder
    av1Decoder*: dav1d.Decoder
    control: ptr Channel[Control]
      # this must be a pointer to pass it to
      # the demuxer channel- the rest of this object
      # is passed via that channel so can be
      # garbage collected
      # consider this a hack
    packet: ptr Channel[Packet]
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
  DecmuxInit* = tuple[demuxer: Demuxer, av1Decoder: dav1d.Decoder, opusDecoder: opus.Decoder, packet: ptr Channel[Packet], control: ptr Channel[Control]]

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

  while true:

    for packet in decmuxInit.demuxer:

      case packet.track.kind:
      of tkAudio:
        case packet.track.audioCodec:
        of acOpus:
          for chunk in packet:
            var decoded = Packet(kind: pktAudio)
            decoded.samples = decmuxInit.opusDecoder.decode(chunk.data, chunk.len)
            decoded.timestamp = packet.timestamp
            decmuxInit.packet[].send(decoded)
        else:
          raise newException(ValueError, "codec $# not supported" % $packet.track.audioCodec)
      of tkVideo:
        case packet.track.videoCodec:
        of vcAv1:
          for chunk in packet:
            try:
              decmuxInit.av1Decoder.send(chunk.data, chunk.len)
            except BufferError:
              # TODO: handle
              raise getCurrentException()

            # video decode and delay for timing source
            var decoded = Packet(kind: pktVideo)
            try:
              decoded.picture = decmuxInit.av1Decoder.getPicture()
              decoded.timestamp = packet.timestamp
              decmuxInit.packet[].send(decoded)
            except BufferError:
              # TODO: handle
              raise getCurrentException()

        else:
          # TODO: handle unknown packet codec
          discard
      else:
        # TODO: handle packet
        discard

      let (received, control) = decmuxInit.control[].tryRecv
        ## Check if a seek was requested and handle it
      if received:
        case control.kind:
        of cSeek:
          while decmuxInit.packet[].tryRecv.dataAvailable:
            # flush channel buffer
            discard
          decmuxInit.demuxer.seek(control.timestamp)
          decmuxInit.av1Decoder.flush()

        of cInit:
          raise newException(Defect, "already initialized")

    decmuxInit.packet[].send(Packet(kind: pktDone))
      # notify demuxing has completed

    let control = decmuxInit.control[].recv()
      # Wait for a seek, rather than merely checking for a seek with tryRecv,
      # because there is no demuxing so nothing else to do while we wait
    case control.kind:
    of cSeek:
      while decmuxInit.packet[].tryRecv.dataAvailable:
        # flush channel buffer
        discard
      decmuxInit.demuxer.seek(control.timestamp)
      decmuxInit.av1Decoder.flush()
    of cInit:
      raise newException(Defect, "already initialized")


proc cleanup*(lov: Lov) =
  deallocShared(lov.control)
  deallocShared(lov.packet)

proc newLov*(demuxer: Demuxer, queueSize = 5): Lov =
  new(result, cleanup)
  result.demuxer = demuxer
  result.av1Decoder = dav1d.newDecoder()
  result.opusDecoder = opus.newDecoder(sr48k, chStereo)
    # opus is supposed to decode at 48k stereo and then downsample and/or downmix

  result.control = cast[ptr Channel[Control]](allocShared0(sizeof(Channel[Control])))
  result.packet = cast[ptr Channel[Packet]](allocShared0(sizeof(Channel[Packet])))
    # this gets cleaned up with function above
  result.control[].open(1)
  result.packet[].open(queueSize)
    # todo: buffer control messages and drop the right ones
  result.decmux.createThread(decmux, result.control)

  result.control[].send(Control(kind: cInit, decmuxInit: (
    demuxer: result.demuxer,
    av1Decoder: result.av1Decoder,
    opusDecoder: result.opusDecoder,
    packet: result.packet,
    control: result.control
  )))

proc getPacket*(lov: Lov): Packet =
  ## Wait for a packet form the demuxer-decoder. A packet could be
  ## a decoded frame of video, a decoded chunk of audio samples, or
  ## a flag that demuxing-decoding is complete.
  lov.packet[].recv()

proc seek*(lov: Lov, timestamp: uint64) =
  ## Instruct the demuxer-decoder to change its timestamp to the specified time
  ## in nanoseconds.
  lov.control[].send(Control(kind: cSeek, timestamp: timestamp))
