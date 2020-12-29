# Package

version       = "0.1.0"
author        = "Carlo Capocasa"
description   = "lov is the latest open video, a simplified, portable video player for webm/av1/opus"
license       = "2BSD"
bin           = @["lov"]
installExt    = @["nim"]

# Dependencies

requires "nim >= 1.4.2"
requires "nestegg"
requires "dav1d"
requires "sdl2"
requires "opus"
