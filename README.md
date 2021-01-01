
lov
===

lov stands for the "latest open video" and is a minimalistic SDL video player library. It is deliberately monolithic and restricted to a single file format to simplify it as much as possible while retaining enough functionality to be used for where the application author has control over the content authoring process.

Design criteria
---------------

I wanted modern video for the nimx cross-platform app framework, which meant that all code used needs to portable across all nimx targets- Linux, OSX, Windows, iOS, Android and Emscripten (but not js)- and legally compatible. This calls for simple, proven, high-performance libraries written in C. I further wanted the interface to be as Nim-flavored as possible, which implies low-cost high level language features, thread-safety and automatic memory management.

Road map
--------

lov is, right now, a preview release. It works fine at what it does but misses most features commonly expected from a video player application.

It does work well enough that I would consider it suitable as a starting point for integrating the wrapped libraries into your own application- copy-paste the demuxer-decoder and presenter threads and integrate them with your needs.

[x] webm demuxing
[x] av1 video decoding
[x] opus audio decoding
[ ] Basic command-line usage
[ ] Good High-level library interface
[ ] Library documentation
[ ] Pause, play, pause and seek
[ ] Resizing and fullscreen
[x] Testing on linux
[ ] Testing on OSX
[ ] Testing on Windows
[ ] Testing on iOs
[ ] Testing on Android
[ ] Testing on wasm
[ ] Testing on asm.js
[ ] Compatibility with Nim 1.0
[ ] Continuous integration on linux
[ ] Address long-term audio-video drift
[ ] Get rid of 1ms video frame jitter

Usage as command-line tool
--------------------------

$ lov myFile.webm

# That's it, it will open an SDL window of appropriate size and play the file.

Usage as library
----------------

The heart of lov is the demuxer-decoder, a simple iterator that you call with a file name and then receive audio and video packets from.

The second important component is the presenter that displays buffered frames at the correct time and queues audio. The two threads are
glued together using standard Nim channels.

Currently, the author has not figured out yet how to set up such a threaded pipeline without being unduly limiting- you could be using
weave for threads, or your own finely-tuned SDL setup, or prefer your own data structures. It is therefore currently recommended to
copy-paste relevant portions of lov code into your application and adapt them to your unique needs.

There are, however, some higher level functions to be extracted that can be exposed as a library- those are planned to be.

File Format
-----------

Currently, the following file format was chosen as the "latest and greatest in open video":

* A WebM container (demuxed by nestegg, by mozilla)
* OM AV1 video (decoded by dav1d, by VideoLAN)
* OPUS audio (decoded by libopus, by Xiphophorus

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

Video credit
------------

Test data from [Showreel by Anne Roemeth](https://vimeo.com/292581643). Used with permission.
