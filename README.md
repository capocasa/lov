
lov
===

lov stands for the "latest open video" and is a minimalistic SDL video player library.

Why lov?
--------

Lov is primarily intended to be used as a video playback library within applications where the video authoring process can be controlled by the application author. Therefore, it only supports one video format: The best-performing one available without licensing restricitons, leveraging the fastest, smallest and most portable libraries available. At the time of writing, this is a webm container with av1 video and opus audio, wrangled by nestegg, libopus and dav1d, respectively.

Lov provides a nim-flavored interface while making few extremely minor speed compromises.

Performance
-----------

No formal benchmarks were done yet, however repeated manual measuring seems to indicate that lov performs 30%-50% better than mplayer, mpv or vlc on the same source file. I have no idea why- the same decoders are used by all players.

Road map
--------

lov is, right now, a preview release. It works fine at what it does but misses features commonly expected from a video player application.

It does work well enough that I would consider it suitable as a starting point for integrating the wrapped libraries into your own application- copy-paste the demuxer-decoder and presenter threads and integrate them with your needs.

- [x] webm demuxing
- [x] av1 video decoding
- [x] opus audio decoding
- [x] thread safety
- [x] Automatic memory management
- [x] Basic command-line usage
- [ ] Good High-level library interface
- [ ] Library documentation
- [ ] Pause, play, pause and seek
- [ ] Test for memory related crashes
- [ ] Test for memory leaks
- [x] Resizing and fullscreen
- [x] Testing on linux
- [ ] Testing on OSX
- [ ] Testing on Windows
- [ ] Testing on iOs
- [ ] Testing on Android
- [ ] Testing on wasm
- [ ] Testing on asm.js
- [ ] Compatibility with Nim 1.0
- [ ] Continuous integration on linux
- [ ] Evaluate possible long-term audio-video drift
- [ ] Get rid of 1ms video frame jitter
- [ ] Get rid of sdl2 dependency for library-only build *
- [ ] Test with ARC and ORC

* seems to depend on [nimble optional-dependencies](https://github.com/nim-lang/nimble/issues/506) feature

Usage as command-line tool
--------------------------

```
$ lov resources/test.webm

# That's it, it will open an SDL window of appropriate size and play the file.
```

Once the lov player is running, it will play the duration of the file, and then end at the last frame. The player can be controlled using the following keys:

| ESC / Q  | Exit the player   |
| HOME     | Skip to beginning |

Usage as library
----------------

The heart of lov is the threaded demuxer-decoder that you call with a file name and then receive audio and video packets from an exposed Nim Channel.

```
var l = newLov("myfile.webm")

var run = true
while run:

  # wait for a packet containing a demuxed packet
  let packet = l.packet[].recv()

  case packet.kind:

  of pktVideo:
    handleVideoData(packet.picture)

  of pktAudio:
    handleAudioSamples(packet.samples)

  of pktDone:
    run = false

```

Please see the lov command line tool in `cmd.nim` for a full SDL2 example of the decoder-demuxer. Note that programs must be compiled with --threads=on to use the lov library.

Further, note that the lov library does not depend on sdl2- the command-line tool does.

File Format
-----------

Currently, the following file format was chosen as the "latest and greatest in open video":

* A WebM container (demuxed by [nestegg](https://github.com/capocasa/nim-nestegg), by mozilla)
* OM AV1 video (decoded by [dav1d](https://github.com/capocasa/nim-dav1d), by VideoLAN)
* OPUS audio (decoded by [libopus](https://github.com/capocasa/nim-opus), by Xiphophorus

Note that AV1 support is unofficial, but it is widely considered only a formality at this point.

The following criteria guided the choice of libraries:

(1) as simple as possible in design and implementation
(2) as freely usable as possible
(3) high performance and high quality

For this reason, 2 of 3 wrappers

Authoring
---------

Make sure that mySourceFile.mp4 has a single video and a single stereo audio track, and use this command:

    ffmpeg -i input.mp4 -c:a libopus -sample_fmt s16 -c:v librav1e output.webm

Other input formats can be used as well as supported by ffmpeg, as well as various flags to tune size, resolution and quality. The command can also use arbitrary fmpeg options. The following will extract a very short clip from the middle
of the input file and resize to 720p:

    ffmpeg -i input.mp4 -s 720x480 -ss 0:00:22.2 -t 0:00:22.8 -c:a libopus -sample_fmt s16 -c:v librav1e snipped.webm

The fastest available AV1 encoder is used with this command, but the encoding process is still on the slow end compared to other codecs- this appears to be the price of the size-quality ration achieved with AV1.

Design details 
---------------

I wanted modern video for the [nimx cross-platform app framework](https://github.com/yglukhov/nimx), which meant that all code used needs to portable across all nimx targets- Linux, OSX, Windows, iOS, Android and Emscripten (but not js)- and legally compatible. This calls for simple, proven, high-performance libraries written in C. I further wanted the interface to be as Nim-flavored as possible, which implies low-cost high level language features, thread-safety and automatic memory management.

A few minor speed compromises are made: C-allocated objects are wrapped into Nim objects with Nim references, using finalizers to free them. The price of this is double indirection- one for the ref, one for the ptr. This does not seem to have a noticable impact on performance, but may be of concern on the lowest end systems. Another compomise was made with eager initialization: When a C library offers accessor functions to a struct, those are eagerly copied into the Nim container at initialization time. This, too, does not seem to noticably affect performance.

Video credit
------------

Test data from [Showreel by Anne Roemeth](https://vimeo.com/292581643). Used with permission.
