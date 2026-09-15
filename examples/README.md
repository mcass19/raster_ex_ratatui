# Examples

A catalog of `raster_ex_ratatui` examples. None of them needs a terminal.

## In this repository

| Example | What to see |
|---------|-------------|
| [`headless/snapshot.exs`](headless/snapshot.exs) | A dashboard with text, a gauge, a sparkline, and a `Viewport3D` cube rasterised twice from the same widgets: a colour frame (`XRGB8888` at scale 2, written as PPM) and a 1-bit e-ink frame (`Mono`, written as PGM). Runs anywhere: `mix run examples/headless/snapshot.exs`. |
| [`bench/raster_bench.exs`](bench/raster_bench.exs) | Rasterisation cost on a 1080p panel (a 106×45 grid at scale 3, `XRGB8888`): a full repaint cold and warm, a full frame, a handful of changed cells, one row, and pixel regions of two sizes, as median times. `mix run examples/bench/raster_bench.exs`. |

## On devices

| Example | What to see |
|---------|-------------|
| [Goatmire name badge](https://github.com/mcass19/name_badge/tree/raster_ex_ratatui) | The consumer the library was extracted from: a 400×300 1-bit e-ink panel on Nerves. The badge keeps its own screen process and uses the pure core: `Raster.apply/2` folds each diff, `Patch.blit/4` writes the patches over a kept gray8 frame, queued diffs are drained so one refresh shows the latest frame, and a crash frame replaces the app when it dies. Two GPIO buttons become `ExRatatui.Event.Key` events. A branch of the [name_badge](https://github.com/protolux-electronics/name_badge) fork; see the worked example in [Building a Surface](https://hexdocs.pm/raster_ex_ratatui/surfaces.html). |
| Raspberry Pi 4 with the Touch Display 2 | A `RasterExRatatui.Surface` on `/dev/fb0` (`XRGB8888`, scale 3) with a USB keyboard read through [`input_event`](https://hex.pm/packages/input_event) and translated by `Input.Evdev`, as a Nerves project under `examples/`. In progress: it lands after its first device run. [Linux Framebuffers](https://hexdocs.pm/raster_ex_ratatui/framebuffer.html) already shows the surface and the device checks it uses. |

## Where to start

Run `headless/snapshot.exs` and open the two images: it is the whole pipeline (app widgets, `CellSession` diff with a pixel region, `Raster.apply/2`, `Raster.frame/1`) in one file, and the same widgets under two pixel formats show what a format decides. Then read the badge for a panel driven from an existing process, or the Pi for the surface process on a framebuffer.

## Related guides

- [Building a Surface](https://hexdocs.pm/raster_ex_ratatui/surfaces.html) — the contract a device implements.
- [Fonts](https://hexdocs.pm/raster_ex_ratatui/fonts.html) and [Pixel Formats](https://hexdocs.pm/raster_ex_ratatui/pixel_formats.html) — making the output fit a panel.
