# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `examples/rpi_framebuffer`: a Nerves project that runs a `RasterExRatatui.Surface` on a Raspberry Pi's `/dev/fb0` with a USB keyboard. The panel's size, pixel format, and font scale are read from sysfs, so the same firmware fits the DSI Touch Display 2 and an HDMI monitor. The app is a three-tab dashboard (pixel regions, system monitor, keyboard test) that also runs in a terminal.
- `examples/e_ink`: a walk through the e-ink name badge, the consumer that uses the pure core from its own screen process instead of a surface.
- `RasterExRatatui.Raster.apply/2` takes a list of payloads and rasterises them as one: the grid is folded through all of them first, so a cell or region that changed several times is drawn once, in its final state. The patches are those of the last state only.

- `RasterExRatatui.PixelFormat` gains an optional `rgb_row/4` callback that packs a whole row of region pixels in one call, plus `RasterExRatatui.PixelFormat.rgb_row/5`, the per-pixel fallback the raster uses for formats without one. `Mono`, `RGB565`, and `XRGB8888` implement it.

### Changed

- Region rasterisation goes row by row: the raster hands each source row to the format's `rgb_row/4` instead of calling `rgb_pixel/6` per pixel, gathers scaled rows once instead of per pixel, and reuses a source row an upscaled region repeats. A 954×528 region costs 14 ms instead of 35 on the host; on a Raspberry Pi 4 a 696×480 `Viewport3D` region went from 184 ms to 43 ms per frame.
- The surface process folds renders instead of queuing them. When a diff arrives, every diff already waiting in the mailbox goes with it through one `Raster.apply/2` and one push, right away; before, each diff was rasterised on its own and the push went through a self-sent message that queued behind every render still waiting, so a panel whose raster took longer than the app's tick fell further behind on every frame (on a Raspberry Pi 4 with a turning `Viewport3D` region: one push every ~5 s, ~28 stacked copies of the same rectangle per push, and key presses ~5 s late). Now the panel shows fewer, later frames and input never waits behind stale renders. `min_interval:` holds the batch back on a timer instead of rasterising in between. The `[:raster_ex_ratatui, :frame, :raster]` `:stop` metadata gains `:diffs`, how many were folded into the call.
- `RasterExRatatui.Raster.apply/2` rasterises only the pixel regions that are new or changed, instead of every region whenever the region list changed. A still `Image` next to an animated `Viewport3D` is now rasterised once, which halves the per-frame cost of that layout. Overlapping regions stay correct: an unchanged region that touches a repainted area is repainted with it, in list order, and unchanged regions that swap order are all repainted. Patches still reproduce `frame/1` exactly.
- `examples/README.md` is a catalogue page with a row per example; the device examples carry their own READMEs. The Linux Framebuffers and Building a Surface guides point at them.

## [0.1.0] - 2026-09-15

### Added

- **First release.** `raster_ex_ratatui` renders `ExRatatui` apps on pixel displays that are not terminals, on top of `ExRatatui.CellSession` pixel regions.
- `RasterExRatatui.Surface`: a behaviour with `use` defaults whose supervised process starts the app on a cell session, folds every diff through the raster, and calls the consumer's `push/2` with changed rectangles (`push_mode: :patches`) or whole frames (`push_mode: :frame`). Renders that arrive while `push/2` is busy are pushed together, so a slow device never builds a backlog; `min_interval:` additionally throttles pushes for slow panels. `send_event/2` forwards input, `resize/2` rebuilds the grid (diffs rendered for the old size are dropped), the surface exits with the app's exit reason under a `:transient` child spec, and `shutdown_timeout:` bounds how long it waits for the app to stop.
- `RasterExRatatui.Raster`: the pure rasteriser. `apply/2` returns `RasterExRatatui.Patch` rectangles for changed cells, changed pixel regions (scaled nearest-neighbour onto their cell rect), and margins on a full repaint; `frame/1` renders the whole panel and `render_frame/1` does the same while keeping the glyph cache. Cells under a pixel region are never rasterised. Cell pixels are cached per glyph and colours.
- `RasterExRatatui.Font` behaviour with the built-in `Font.Default6x8` (hand-drawn printable ASCII, light box drawing and the corners of every `Block` border type, blocks, and common symbols; generated braille, eighth blocks, and quadrants), `Font.Art` for compile-time ASCII-art glyphs, and `Font.Generated` for the geometric blocks at any cell size. An integer `scale:` magnifies any font.
- `RasterExRatatui.PixelFormat` behaviour with `Mono` (gray8 for 1-bit panels: tone rules for cells, Bayer 4×4 dither for regions), `RGB565`, and `XRGB8888`, and `RasterExRatatui.Palette` for named, indexed, RGB, and `:reset` colours with a configurable theme.
- `RasterExRatatui.Framebuffer`: Linux fbdev geometry from sysfs, stride-aware patch and frame writes, blanking, and console unbinding.
- `RasterExRatatui.Input.Evdev`: a pure evdev key translator producing `ExRatatui.Event.Key` structs with shift, ctrl, alt, super, and caps lock, for a US layout or a custom map.
- `RasterExRatatui.Telemetry`: surface start/stop, rasterisation and push spans, and input forwarding events.
- Guides (Building a Surface, Fonts, Pixel Formats, Linux Framebuffers, Telemetry), usage rules, a headless snapshot example, and a rasterisation benchmark.

[Unreleased]: https://github.com/mcass19/raster_ex_ratatui/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mcass19/raster_ex_ratatui/releases/tag/v0.1.0
