# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **A pixel region on a turned panel costs about what it costs on a flat one.** Until now a rotated region was gathered pixel by pixel in Elixir — a panel row is a column of the app's image, so each row of the patch was assembled with one `binary_part` per pixel — which made a region roughly twice as expensive turned as flat. The raster now samples the bitmap onto its rect in the app's orientation, turns it in one pass with `ExRatatui.Pixels.rotate_rgb8/4` (new in ex_ratatui 0.15), and packs whole panel rows through the format's `rgb_row/4`, which is the same path a flat region already took. On this host one 954×528 XRGB8888 region went from 20.0 ms to 12.4 ms at 90 and from 21.3 ms to 13.6 ms at 270, against 10.4 ms flat; the rotation itself is 0.4 ms of that. The output is byte for byte what it was, at every angle and every scale. Packing stays in Elixir and is now most of what a region costs, turned or not.
- Requires ex_ratatui `~> 0.15`, for `ExRatatui.Pixels.rotate_rgb8/4`.

### Removed

- The rotated region fast path and its helpers (`column/3`, `reverse_rows/2`, and the per-pixel `gather/3`), which the native rotation replaces. Private, so nothing to migrate.

## [0.2.1] - 2026-09-19

### Fixed

- Touch panels produced no mouse events through `input_event`. `input_event` delivers one evdev frame per message and drops the `syn_report` that ends it, and `RasterExRatatui.Input.Touch` only emitted on a `syn_report`, so it followed the finger and never reported it. `Input.Touch.translate_all/2` now takes the end of its list as the end of a frame (an explicit `syn_report` still ends one too), and the tests feed frames in the shape `input_event` sends, including a tap captured on a Raspberry Pi Touch Display 2.

## [0.2.0] - 2026-09-19

### Migration

Nothing breaks for consumers of the documented API. Two things to know:

- Apps started by a surface or a session receive a `surface:` key in their `mount/1` (or reducer `init/1`) options. An app that already used `app_opts: [surface: ...]` for something else gets the library's map instead; rename that option.
- `%RasterExRatatui.Raster{}` has two new enforced fields, `:logical_size` and `:rotate`. Code that builds the struct by hand instead of calling `Raster.new/1` has to add them.

### Added

- `RasterExRatatui.Framebuffer.Surface`: a complete surface for a Linux framebuffer in one `use`: `use RasterExRatatui.Framebuffer.Surface, app: MyApp, rotate: 90` waits for `/dev/fb0`, reads its geometry from sysfs, picks the format from the depth and the scale from the long side (`RasterExRatatui.Framebuffer.auto_scale/2`, new), detaches the framebuffer console, reads the keyboard through `Input.Devices`, writes with `Framebuffer.write/2`, and restarts the app when it quits (`on_app_exit: :restart` by default). Every option is documented in its moduledoc; `init/1`, `push/2`, `handle_info/2`, and `terminate/2` are overridable and each default is a public function an override can call. Without `input_event` in the deps it logs once and runs without input.
- `RasterExRatatui.Session`: the surface without the process, for a consumer that already owns one. `start/2` creates the cell session for a raster and starts the app server linked to the caller; every render arrives as a `{RasterExRatatui.Session, ref, diff}` message that `handle/2` folds (together with every render of the session still waiting) into patches, or `{:exit, reason, session}` when the app exits; `await/2` waits for the first frame; `keep_frame: true` keeps a whole frame current for `frame/1`; `send_event/2`, `resize/2`, `stop/1`, and `drain/2` + `render/2` as the two halves of `handle/2`. `RasterExRatatui.Surface` is now built on it.
- `rotate: 0 | 90 | 180 | 270` on `RasterExRatatui.Raster.new/1`, `RasterExRatatui.Session.start/2`'s raster, and `RasterExRatatui.Surface`, for a panel mounted on its side: the app's image is turned clockwise on its way to the panel. `:size` stays the physical panel and so do every patch, `frame/1`, and `resize/2`, so consumers' `push/2` and `Framebuffer.write/2` are untouched; the grid, the new `Raster.logical_size/1`, and `margin/1` follow the turned image. Glyph blocks are rotated once into the cache, runs of cells become vertical strips, and regions are gathered already turned (a bitmap at panel size turned by 90 or 270 is gathered one column per panel row in a single bit-syntax pass); dithering and checkerboards stay anchored to the panel's pixels. Cells cost the same turned as flat; a turned pixel region costs about 1.6× a flat one on the host and 2× on a Raspberry Pi 4, the price of gathering it pixel by pixel in Elixir. `Raster.rotate/1` reports the angle, and `surface:` carries it to the app.
- `RasterExRatatui.Input.Touch`: a pure translator from evdev touch events (multitouch type B, or single-touch `abs_x`/`abs_y` with `btn_touch`) to `ExRatatui.Event.Mouse` events on the cell under the first finger: `"down"` and `"up"` for a tap, `"drag"` when the finger moves into another cell, nothing in the margins, a second finger ignored. Axes are scaled to the panel's pixels and the cell comes from a `cell_at:` function, normally `Raster.cell_at/2`, so rotation is handled; `swap_xy:`, `invert_x:`, `invert_y:` cover a controller that does not follow the panel. `Input.Devices` reads a touch panel with `touch: true` (found by `touch_path/1`, axes from `touch_axes/1`, grabbed, found again after an unplug) given `size:` and `cell_at:`, and `Framebuffer.Surface` passes both from its own geometry, so `touch: true` there is all a Raspberry Pi with the Touch Display 2 needs.
- `RasterExRatatui.Input.Devices`: the evdev device owner a Linux surface needs, process-less and embeddable. `new/1` + `start/1` look for the keyboard (the first device reporting letter keys, or a given path), start an `input_event` reader on it with the device grabbed, translate its events through `Input.Evdev`, and look again every `retry_ms:` while there is none: at boot, and after an unplug, with the modifiers released. `handle_info/2` takes every message of the owning process and returns `{:events, keys, devices}`, `{:noreply, devices}`, or `:unknown`; `stop/1` stops the readers. `input_event` stays the consumer's dependency: `start/1` returns `{:error, :input_event_missing}` without it. Pure helpers `keyboard_path/1`, `touch_path/1`, and `touch_axes/1` pick devices out of `InputEvent.enumerate/0`. Moved out of the `rpi_framebuffer` example, which adopts it with the one-`use` framebuffer surface.
- `on_app_exit: :stop | :restart` on `RasterExRatatui.Surface`. `:stop` (the default) is today's behaviour: the surface exits with the app's reason and its supervisor decides. `:restart` keeps the surface and its raster, starts the app again at once on a fresh cell session, and lets the new app's first render repaint the panel, for a panel that has nothing else to show. A crash loop does not spin: more than `max_restarts:` crashes (default 3) within `max_seconds:` (default 5) stop the surface with the app's reason after all, so its supervisor takes over; quits on purpose are never counted. Both policies report the exit as the new `[:raster_ex_ratatui, :app, :exit]` telemetry event, with the `:reason` and the `:action` taken; the default logger prints it.
- The app's `mount/1` (or reducer `init/1`) options always include `surface:`, a map with the panel `:size` in pixels, the effective `:cell_size`, the `:grid_size` in cells, the `:format`, the `:scale`, and the `:rotate` angle, so an app can lay itself out for the panel it runs on instead of assuming a cell size.
- `RasterExRatatui.Raster.cell_at/2`: the cell under a physical panel pixel, `{col, row}` or `:outside` (margins, off the panel), whatever the rotation; the inverse mapping a touch controller reporting panel coordinates needs.
- `RasterExRatatui.Raster.to_png/1`: the whole panel as a PNG (8-bit RGB, physical size), pure Elixir with `:zlib`, for tests and debugging. It unpacks pixels through the new optional `c:RasterExRatatui.PixelFormat.unpack_row/2` callback, which `Mono`, `RGB565`, and `XRGB8888` implement; a format without it raises `ArgumentError` naming the callback.
- `RasterExRatatui.Telemetry.probe/3` watches a surface for a few seconds from IEx and reports the raster and push spans (count, median, p90, max) and the surface's mailbox before and after, the quickest way to tell whether a panel keeps up with its app.
- `RasterExRatatui.Raster.apply/2` takes a list of payloads and rasterises them as one: the grid is folded through all of them first, so a cell or region that changed several times is drawn once, in its final state. The patches are those of the last state only.
- `RasterExRatatui.PixelFormat` gains an optional `rgb_row/4` callback that packs a whole row of region pixels in one call, plus `RasterExRatatui.PixelFormat.rgb_row/5`, the per-pixel fallback the raster uses for formats without one. `Mono`, `RGB565`, and `XRGB8888` implement it.
- `examples/rpi_framebuffer`: a Nerves project that puts a dashboard on a Raspberry Pi's `/dev/fb0` with a USB keyboard, through one `use RasterExRatatui.Framebuffer.Surface`. The panel's size, pixel format, and font scale are read from sysfs, so the same firmware fits the DSI Touch Display 2 (turned landscape with `rotate:`) and an HDMI monitor. The app is a two-tab dashboard (pixel regions, keyboard test) that reads its cell size from the `surface:` option and also runs in a terminal.
- `examples/e_ink`: the e-ink name badge, the consumer that runs its apps with `RasterExRatatui.Session` from its own screen process instead of a surface.
- The Nerves Quick Start guide: from `mix nerves.new` to an app on a Raspberry Pi's display with keyboard and touch, the build traps (OTP-matched Elixir, the host NIF in firmware builds), first checks over SSH, and what to do when the panel stays dark.

### Fixed

- `RasterExRatatui.Raster.resize/2` no longer calls the format's `init/1` a second time with empty options (it reuses the raster's config), so formats whose `init/1` rejects `[]` survive a resize.
- `RasterExRatatui.Raster.new/1` raises `ArgumentError` for a missing `:size` or `:format`, and for a `:size` that is not a pair of positive integers, instead of `KeyError` or `MatchError`. A `RasterExRatatui.Surface` whose `init/1` returns something other than `{:ok, opts, state}` or `{:stop, reason}` raises `ArgumentError` naming the module and the value, instead of `FunctionClauseError`.
- `RasterExRatatui.Input.Evdev.translate_all/2` accepts the `:disconnect` that `input_event` sends in place of the event list when a device goes away: held modifiers are released and no keys are produced. The Linux Framebuffers guide's surface sketch handles it, and stops its reader in `terminate/2`: a reader that is only linked survives a surface that stops normally (its app quit) and keeps its grab on the keyboard, so the next surface's reader was disconnected at once, and the `rpi_framebuffer` example crashed on that message three times and took the application down. The example now does both.

### Changed

- The child spec that `use RasterExRatatui.Surface` generates sets `:shutdown` to `shutdown_timeout + 1_000` instead of the default 5 seconds, so raising `shutdown_timeout:` no longer lets the supervisor kill the surface in the middle of the consumer's `terminate/2`.
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

[Unreleased]: https://github.com/mcass19/raster_ex_ratatui/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/mcass19/raster_ex_ratatui/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mcass19/raster_ex_ratatui/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mcass19/raster_ex_ratatui/releases/tag/v0.1.0
