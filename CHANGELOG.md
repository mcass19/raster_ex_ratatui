# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `examples/rpi_framebuffer`: a Nerves project that runs a `RasterExRatatui.Surface` on a Raspberry Pi's `/dev/fb0` with a USB keyboard. The panel's size, pixel format, and font scale are read from sysfs, so the same firmware fits the DSI Touch Display 2 and an HDMI monitor. The app is a two-tab dashboard (pixel regions, keyboard test) that also runs in a terminal.
- `examples/e_ink`: a walk through the e-ink name badge, the consumer that uses the pure core from its own screen process instead of a surface.
- `RasterExRatatui.Raster.apply/2` takes a list of payloads and rasterises them as one: the grid is folded through all of them first, so a cell or region that changed several times is drawn once, in its final state. The patches are those of the last state only.

- `RasterExRatatui.Telemetry.probe/3` watches a surface for a few seconds from IEx and reports the raster and push spans (count, median, p90, max) and the surface's mailbox before and after, the quickest way to tell whether a panel keeps up with its app.
- `RasterExRatatui.PixelFormat` gains an optional `rgb_row/4` callback that packs a whole row of region pixels in one call, plus `RasterExRatatui.PixelFormat.rgb_row/5`, the per-pixel fallback the raster uses for formats without one. `Mono`, `RGB565`, and `XRGB8888` implement it.
- `on_app_exit: :stop | :restart` on `RasterExRatatui.Surface`. `:stop` (the default) is today's behaviour: the surface exits with the app's reason and its supervisor decides. `:restart` keeps the surface and its raster, starts the app again at once on a fresh cell session, and lets the new app's first render repaint the panel, for a panel that has nothing else to show. Both report the exit as the new `[:raster_ex_ratatui, :app, :exit]` telemetry event, with the `:reason` and the `:action` taken; the default logger prints it.
- `rotate: 0 | 90 | 180 | 270` on `RasterExRatatui.Raster.new/1`, `RasterExRatatui.Session.start/2`'s raster, and `RasterExRatatui.Surface`, for a panel mounted on its side: the app's image is turned clockwise on its way to the panel. `:size` stays the physical panel and so do every patch, `frame/1`, and `resize/2`, so consumers' `push/2` and `Framebuffer.write/2` are untouched; the grid, the new `Raster.logical_size/1`, and `margin/1` follow the turned image. Glyph blocks are rotated once into the cache, runs of cells become vertical strips, and regions are gathered already turned, so a rotated frame costs about what a flat one does; dithering and checkerboards stay anchored to the panel's pixels. `Raster.rotate/1` reports the angle, and `surface:` carries it to the app.
- `RasterExRatatui.Raster.cell_at/2`: the cell under a physical panel pixel, `{col, row}` or `:outside` (margins, off the panel), whatever the rotation; the inverse mapping a touch controller reporting panel coordinates needs.
- `RasterExRatatui.Session`: the surface without the process, for a consumer that already owns one. `start/2` creates the cell session for a raster and starts the app server linked to the caller; every render arrives as a `{RasterExRatatui.Session, ref, diff}` message that `handle/2` folds (together with every render of the session still waiting) into patches, or `{:exit, reason, session}` when the app exits; `await/2` waits for the first frame; `keep_frame: true` keeps a whole frame current for `frame/1`; `send_event/2`, `resize/2`, `stop/1`, and `drain/2` + `render/2` as the two halves of `handle/2`. `RasterExRatatui.Surface` is now built on it.
- The app's `mount/1` (or reducer `init/1`) options always include `surface:`, a map with the panel `:size` in pixels, the effective `:cell_size`, the `:grid_size` in cells, the `:format`, the `:scale`, and the `:rotate` angle (always `0` for now), so an app can lay itself out for the panel it runs on instead of assuming a cell size.

### Fixed

- `RasterExRatatui.Raster.resize/2` no longer calls the format's `init/1` a second time with empty options (it reuses the raster's config), so formats whose `init/1` rejects `[]` survive a resize.
- `RasterExRatatui.Raster.new/1` raises `ArgumentError` for a missing `:size` or `:format`, and for a `:size` that is not a pair of positive integers, instead of `KeyError` or `MatchError`. A `RasterExRatatui.Surface` whose `init/1` returns something other than `{:ok, opts, state}` or `{:stop, reason}` raises `ArgumentError` naming the module and the value, instead of `FunctionClauseError`.

- `RasterExRatatui.Input.Evdev.translate_all/2` accepts the `:disconnect` that `input_event` sends in place of the event list when a device goes away: held modifiers are released and no keys are produced. The Linux Framebuffers guide's surface sketch handles it, and stops its reader in `terminate/2`: a reader that is only linked survives a surface that stops normally (its app quit) and keeps its grab on the keyboard, so the next surface's reader was disconnected at once, and the `rpi_framebuffer` example crashed on that message three times and took the application down. The example now does both.

### Changed

- `RasterExRatatui.Raster.frame/1` composes each row from its patches without copying the row once per patch (a scanline sweep over the few patches instead of a map of every slice): a flat 1920×1080 frame takes 23 ms instead of 30 on the host, and a rotated one 38 ms instead of 148.
- `push_mode: :frame` applies each render's patches to a frame the surface keeps (`RasterExRatatui.Session`'s `keep_frame:`) instead of rasterising the patches and then rendering the whole panel again; the frame pushed is the same.
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
