# Package

version       = "0.1.0"
author        = "Carlo Capocasa"
description   = "An example webm/AV1 video player using nestegg, dav1d and opus"
license       = "2BSD"
bin           = @["nimvideo"]
installExt    = @["nim"]

# Dependencies

requires "nim >= 1.4.2"
requires "nestegg"
requires "dav1d"
requires "sdl2"

