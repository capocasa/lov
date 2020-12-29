
lov
===

lov stands for the "latest open video" and is a minimalistic SDL video player library. It is deliberately monolithic and restricted to a single file format to simplify it as much as possible while retaining enough functionality to be used for where the application author has control over the content authoring process.

Portable, liberally licensed statically linked libraries written in C are used to ensure the widest possible portability. While the library itself does not use multi-threading, it is designed to be run in its own thread. The dav1d decoder also uses multi-threading internally.

Currently, the following format is used:

* A WebM container (demuxed by nestegg, by mozilla)
* OM AV1 video (decoded by dav1d, by VideoLAN)
* OPUS audio (decoded by libopus, by Xiphophorus
WebM and OPUS are already widely used while AV1 is in the process of being rolled out.

To author a file:

Make sure that mySourceFile.mp4 has a single video and a single stereo audio track, and use this command:

    ffmpeg -i input.mp4 -c:a libopus -sample_fmt s16 -c:v librav1e output.webm

The command can be modified to use further fmpeg options. The following will extract a very short clip from the middle
of the input file and resize to 720p:

    ffmpeg -i input.mp4 -s 720x480 -ss 0:00:22.2 -t 0:00:22.8 -c:a libopus -sample_fmt s16 -c:v librav1e snipped.webm

The fastest available AV1 encoder is used with this command, but the encoding process is still comparatively slow.


