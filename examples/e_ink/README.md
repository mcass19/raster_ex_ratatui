# E-ink name badge

ExRatatui apps on a 400×300 1-bit e-ink panel: the [Goatmire name badge](https://github.com/protolux-electronics/name_badge), a Nerves device with two buttons. The code lives in a fork of the badge firmware, not in this folder: **[mcass19/name_badge#3](https://github.com/mcass19/name_badge/pull/3)**.

## Why not a surface

A `RasterExRatatui.Surface` would be a second process whose `push/2` still had to message the screen process, which is the one allowed to talk to the display. And a surface exits when its app exits, which is right under a supervisor but wrong here: the badge wants a crash frame, not a dead screen. Devices that already have a process in charge of the panel are what `RasterExRatatui.Session` is for: the app server, cell session, and raster started from that process, its renders folded with `Session.handle/2`, the kept frame from `Session.frame/1`, the app's exit as `{:exit, reason, session}`. See "Own process" in [Building a Surface](https://hexdocs.pm/raster_ex_ratatui/surfaces.html).

## Things specific to 1-bit panels

- `PixelFormat.Mono` produces gray8 (0 is ink, 255 is paper). Cells follow tone rules (dark colours become ink, light ones paper, the middle band a checkerboard) and pixel regions get a Bayer 4×4 ordered dither. See [Pixel Formats](https://hexdocs.pm/raster_ex_ratatui/pixel_formats.html).
- Photos need preparing: a 1-bit dither turns midtones into dot patterns, so the Showcase photos were contrast-stretched first.
- Every render is a panel refresh. The apps return `render?: false` for messages that change nothing, and tick every 2 to 3 seconds.

