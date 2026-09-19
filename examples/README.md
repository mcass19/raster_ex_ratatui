# Examples

## Headless

| Example | Run | What to see |
|---------|-----|-------------|
| [`snapshot.exs`](https://github.com/mcass19/raster_ex_ratatui/blob/main/examples/headless/snapshot.exs) | `mix run examples/headless/snapshot.exs` | A dashboard with text, a gauge, a sparkline, and a `Viewport3D` cube rasterised twice from the same widgets: a colour frame (`XRGB8888` at scale 2) and a 1-bit e-ink frame (`Mono`), both written as PNG. App widgets, a `CellSession` diff with a pixel region, `Raster.apply/2`, and `Raster.to_png/1` in one file; the two images show what a pixel format decides. |

## Bench

| Example | Run | What to see |
|---------|-----|-------------|
| [`raster_bench.exs`](https://github.com/mcass19/raster_ex_ratatui/blob/main/examples/bench/raster_bench.exs) | `mix run examples/bench/raster_bench.exs` | Rasterisation cost on a 1080p panel (a 106×45 grid at scale 3, `XRGB8888`): a full repaint cold and warm, a full frame, a handful of changed cells, one row, and pixel regions of two sizes, as median times. |

## Devices

| Example | Panel | What to see |
|---------|-------|-------------|
| [`rpi_framebuffer/`](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples/rpi_framebuffer) | Any Raspberry Pi display on `/dev/fb0`; first hardware a Pi 4 with the Touch Display 2 (720×1280, RGB565) | The framebuffer surface in one `use`: size, depth, format, and scale from sysfs, the console detached, a USB keyboard found and found again, the app restarted when it quits, `rotate:` for the stand. The app is a two-tab dashboard: a `Viewport3D` object and a colour photo as pixel regions, and a keyboard test. It also runs in a terminal (`RpiFramebuffer.run/0`), and its tests drive the surface against a fake sysfs. |
| [`e_ink/`](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples/e_ink) | 400×300 1-bit e-ink, the Goatmire name badge | `Session`, without a surface. The badge's own screen process runs each app with `RasterExRatatui.Session`, folds its renders into a kept gray8 frame so one slow refresh shows the latest one, and draws a crash frame when the app dies. Two GPIO buttons become `ExRatatui.Event.Key` events. The folder is a guide to the code, which lives in a [pull request](https://github.com/mcass19/name_badge/pull/3) on a fork of the badge firmware. |

## Related guides

- [Building a Surface](../guides/surfaces.md) — the contract a device implements.
- [Linux Framebuffers](../guides/framebuffer.md) — `/dev/fb0`, the kernel console, keyboards.
- [Fonts](../guides/fonts.md) and [Pixel Formats](../guides/pixel_formats.md) — making the output fit a panel.
