# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
