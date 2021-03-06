
lov
===

lov stands for the "latest open video" and is a minimalistic SDL video player library that comes with a minimal command line player.

Why lov?
--------

Use lov when you only need one video format, but need the highest quality video, using the least CPU and memory, in a highly portable way, using open media formats, with a liberal license.

In practice, this usually means commercial or open-source applications targeting mobile, embedded, or any kind of older device.

Lov provides a nim-flavored development interface that abstracts away multi-threading and memory managmenet while making extremely minor speed compromises.

Features
--------

The lov library comes with a decoder-demuxer iterator that takes a valid file and outputs the decoded packets that can then be rendered by video and audio. That's all.

The lov command line player supports a minimal set of features commonly required by a video player and serves as a usage example.

Performance
-----------

The lov command line player uses about 30% less cpu than mplayer and consumes about 20% less memory, as expected simply because there very little code being run. No copies of encoded or decoded audio/video data are made.

Road map
--------

lov works at its most basic task, but is not just yet usable as a player. Performance is really good though, so when the bugs are fixed this will be nice.

- [x] Fix A/V sync
- [x] Fix skipping
- [ ] Fix all memory leaks
- [x] webm demuxing
- [x] av1 video decoding
- [x] opus audio decoding
- [x] thread safety
- [x] Automatic memory management
- [x] Basic command-line usage
- [x] Support ARC and ORC
- [ ] Freeze High-level library interface
- [x] Library documentation
- [x] Pause, play, pause and seek
- [x] Test for memory related crashes
- [x] Resizing and fullscreen
- [x] Evaluate possible long-term audio-video drift *fixed, syncs to audio*
- [x] Testing on linux
- [ ] Testing on OSX
- [x] Testing on Windows
- [ ] Testing on iOs
- [ ] Testing on Android
- [ ] Testing on wasm
- [ ] Testing on asm.js
- [ ] Continuous integration on linux
- [ ] permit use of dav1d frame/tile threads for even better performance (needs decoder loop revamp)
- [ ] Do nice performance tests
- [ ] Get rid of 1ms video frame jitter (kind of hard to do cross-platform, hi-res timers seem to need polling)
- [ ] Get rid of sdl2 dependency for library-only build (1)
- [ ] Compatibility with Nim 1.0 *low priority*
- [ ] Support default GC *low priority*

*(1) seems to depend on [nimble optional-dependencies](https://github.com/nim-lang/nimble/issues/506) feature*

Installation
------------

lov can be installed using the nimble build system:

    nimble install https://github.com/capocasa/lov

Prerequisites
-------------

lov has a number of prerequisites, mostly build systems for its libraries.

- meson
- autoconf
- make
- libtool
- bash

On linux and OSX, these can be fulfilled using the default package manager.

On Windows, the number of prerequisites is too great to reasonably install them all manually. Instead, it is advised to
install the dependencies using msys2, a system to easily install unix software on Windows.

I personally install all my tools using msys2, including nim, nimble and mingw-w64, but the latter are optional.

(1) Download MSYS2 [from the msys2.org homepage](https://www.msys2.org/) and install it

(2) Open up the msys2 command line and install the required packages:

    pacman -Syu  # update repositories

    pacman -S nim nimble mingw-w64 meson autoconf libtool make nasm

(3) Make the tools accessible in your regular windows command line so they can be picked up by nimterop, the wrapper generator used by lov's dependencies. Add the following paths to your environment variables:

    C:\msys264\usr\bin
      # build tools such as autoreconf and auxiliary commands like bash and perl

    C:\msys264\mingw64\bin
      # compilers, linkers and assemblers

    C:\Users\MyUsername\.nimble\bin
      # installed nimble packages

(4) Make script files accessible in regular windows command line (run this in msys2 bash)

    echo 'perl "%~dp0autoreconf" %*' > /usr/bin/autoreconf
    echo 'perl "%~dp0aclocal" %*' > /usr/bin/aclocal
      #!/usr/bin/perl shim for cmd

Cross compilation is currently not supported- according to nimterop, this is precluded by some limitations in nim, although I'd love to be proven wrong.

Usage as command-line tool
--------------------------

```
$ lov resources/test.webm

# That's it, it will open an SDL window of appropriate size and play the file.
```

Once the lov player is running, it will play the duration of the file, and then end at the last frame. The player can be controlled using the following keys:

| ESC / Q   | Exit the player          |
| Home      | Skip to beginning        |
| Page Up   | Skip 1 minute backward   |
| Page Down | Skip 1 minute forward    |
| Down      | Skip 10 seconds backward |
| Up        | Skip 10 seconds forward  |
| Left      | Skip 1 second backward   |
| Right     | Skip 1 second forward    |

Usage as library
----------------

*Full documentation*

The full [Lov API documentation](https://capocasa.github.io/lov/lov.html)

*Example*

The heart of lov is the threaded demuxer-decoder that you call with a file name and then receive decoded audio and video packets.

```

var l = newLov("myfile.webm")

while true:

  # wait for a packet containing a demuxed packet
  let packet = l.getPacket()

  case packet.kind:

  of pktVideo:
    handleVideoData(packet.picture)

  of pktAudio:
    handleAudioSamples(packet.samples)

  of pktDone:
    break

```

Please see the lov command line tool in `play.nim` for a full SDL2 example of the decoder-demuxer. Note that programs must be compiled with --threads=on to use the lov library.

Further, note that the lov library does not depend on sdl2- the command-line tool does.

Limitations
-----------

Many open bugs.

Only shared-heap garbage collectors are supported- currently orc and arc

The file format is purposely limited to the "latest open video", currently webm/av1/opus, see below.

The player can be affected by SDL audio system related memory leaks on some systems.

The dav1d decoder has a memory pool that grows and is occasionally collected. This seems to be normal behavior managed by dav1d.

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
