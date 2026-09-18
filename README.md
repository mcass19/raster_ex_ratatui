# RasterExRatatui

[![Hex.pm](https://img.shields.io/hexpm/v/raster_ex_ratatui.svg)](https://hex.pm/packages/raster_ex_ratatui)
[![Docs](https://img.shields.io/badge/hex-docs-blue)](https://hexdocs.pm/raster_ex_ratatui)
[![CI](https://github.com/mcass19/raster_ex_ratatui/actions/workflows/ci.yml/badge.svg)](https://github.com/mcass19/raster_ex_ratatui/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/raster_ex_ratatui.svg)](https://github.com/mcass19/raster_ex_ratatui/blob/main/LICENSE)

Render [ExRatatui](https://github.com/mcass19/ex_ratatui) apps on pixel displays such as e-ink panels, with helpers for Linux framebuffers.

A terminal paints glyphs for us. A panel with nothing but pixels does not, so something has to turn every cell (a symbol, a foreground, a background) into pixels, and blit the bitmaps that `Viewport3D` and `Image` render. `RasterExRatatui` is that something. It sits on top of an `ExRatatui.CellSession`, keeps the cell grid and the pixel regions of the current frame, and hands the device only the rectangles that changed, already packed in the panel's pixel format.

```
ExRatatui app ──> ExRatatui.Server ──> CellSession diff (cells + regions)
                                              │
                         RasterExRatatui.Raster  (font × palette × pixel format × scale)
                                              │
                         [%Patch{x, y, width, height, data}]
                                              │
                         Surface.push/2 ──> the panel
```

## Features

- **A surface is one module** — `use RasterExRatatui.Surface`, return the panel geometry from `init/1`, write pixels in `push/2`. The surface process starts the app, folds diffs, rasterises, and forwards input.
- **Patches, not frames** — only changed cells (and changed pixel regions) are rasterised and pushed; `Raster.frame/1` renders a full buffer for panels that want one.
- **Pixel regions** — `Viewport3D` and `Image` arrive as RGB bitmaps and are scaled onto their cell rect at the panel's native resolution.
- **Pixel formats** — `Mono` (1-bit panels: tone rules for cells, Bayer dither for regions), `RGB565`, and `XRGB8888`, with a palette for named, indexed, and RGB colours.
- **Fonts** — a built-in 6×8 bitmap font with box drawing, blocks, and braille, an integer `scale:` for large panels, and a `Font` behaviour to bring another.
- **Device helpers** — `Framebuffer` for Linux fbdev (geometry from sysfs, stride-aware writes) and `Input.Evdev` to turn keyboard events into `ExRatatui.Event.Key` structs.
- **Pure core** — `Raster`, `Grid`, fonts, and formats are plain functions, usable from any process that already owns its device.

## Quick start

The app needs no change: it is a plain `use ExRatatui.App` (or `ExRatatui.run/2`) that renders widgets exactly as it would in a terminal, so build and try it there first. Putting it on a panel is then one module, the surface, that answers three questions about the display: how big it is, how its pixels are packed, and how bytes reach it.

1. **Pick the format and scale.** `Mono` for 1-bit panels, `RGB565` or `XRGB8888` for colour. `scale:` magnifies the built-in 6×8 font so the grid stays readable on a large panel: a 720×1280 display at scale 3 gives 40×53 cells.
2. **Write the surface.** `init/1` opens the device and returns its geometry, `push/2` writes the rectangles that changed. On a Linux framebuffer (a Raspberry Pi with a display) the helpers do both:

   ```elixir
   defmodule MyDevice.Surface do
     use RasterExRatatui.Surface, app: MyDevice.App, scale: 3

     alias RasterExRatatui.Framebuffer

     @impl true
     def init(_opts) do
       {:ok, fb} = Framebuffer.open("fb0")
       {:ok, format} = Framebuffer.format_for(fb.info)
       {:ok, [size: {fb.info.width, fb.info.height}, format: format], fb}
     end

     @impl true
     def push(patches, fb) do
       :ok = Framebuffer.write(fb, patches)
       fb
     end
   end
   ```

   A panel the kernel does not expose as a framebuffer (an SPI LCD, an e-ink controller) writes each patch with its own driver in `push/2` instead.
3. **Supervise it and wire input.** Add `MyDevice.Surface` to the supervision tree and the app is on the display. Whatever reads the hardware (a keyboard, GPIO buttons) turns its events into `ExRatatui.Event` structs and hands them over with `RasterExRatatui.Surface.send_event/2`; `RasterExRatatui.Input.Evdev` does the translation for evdev keyboards.
4. **Test on the host.** A surface whose `push/2` sends patches to the test process drives the real app without a device, and `RasterExRatatui.Raster.frame/1` shows exactly what the panel would.

[Building a Surface](guides/surfaces.md) walks through each step, including panels that only take whole frames, slow refreshes, crashes, and resizing. [Linux Framebuffers](guides/framebuffer.md) covers `/dev/fb0`, keeping the kernel console off the display, and keyboards. A device already driven from its own process can skip the surface and fold diffs with `RasterExRatatui.Raster` directly.

## Examples

- [**Headless snapshot**](https://github.com/mcass19/raster_ex_ratatui/blob/main/examples/headless/snapshot.exs) — the whole pipeline in one file, with no device or terminal: a dashboard with a `Viewport3D` cube rasterised as a colour frame (`XRGB8888`, scale 2) and as a 1-bit e-ink frame (`Mono`), written as PPM and PGM images. `mix run examples/headless/snapshot.exs` from a checkout.
- [**`rpi_framebuffer`**](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples/rpi_framebuffer) — the surface process on a Linux framebuffer, as a Nerves project for any Raspberry Pi display (first hardware: a Pi 4 with the Touch Display 2). Size, depth, and font scale come from sysfs, a USB keyboard comes in through [`input_event`](https://hex.pm/packages/input_event) and `Input.Evdev`, and the app is a two-tab dashboard with a `Viewport3D` object and a colour photo as pixel regions. The same app runs in a terminal.
- [**`e_ink`**](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples/e_ink) — the pure core without a surface: a 400×300 1-bit e-ink name badge on Nerves, driven from the device's existing screen process with `Raster.apply/2` and `Patch.blit/4`, with a crash frame and two GPIO buttons as key events. A guide to the code in a [pull request](https://github.com/mcass19/name_badge/pull/3) on the badge firmware's fork.

The [examples catalog](examples/README.md) says what to look at in each.

## Guides

| Guide | Description |
|-------|-------------|
| [Building a Surface](guides/surfaces.md) | The contract: geometry, push, input, crashes, testing, and a 1-bit e-ink consumer as a worked example |
| [Fonts](guides/fonts.md) | The glyph layout, the built-in 6×8 font, scale, and bringing a font |
| [Pixel Formats](guides/pixel_formats.md) | `Mono` tone rules and dithering, colour palettes, writing a format |
| [Linux Framebuffers](guides/framebuffer.md) | `Framebuffer` and `Input.Evdev`: device geometry, writes, the kernel console, and keyboards |
| [Telemetry](guides/telemetry.md) | Rasterisation, push, and input events with a `Telemetry.Metrics` example |

## Ecosystem

- [ex_ratatui](https://github.com/mcass19/ex_ratatui) — The core terminal UI library this builds on.
- [phoenix_ex_ratatui](https://github.com/mcass19/phoenix_ex_ratatui) — Run TUIs in the browser within [Phoenix LiveView](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.html).
- [kino_ex_ratatui](https://github.com/mcass19/kino_ex_ratatui) — Run TUIs inside [Livebook](https://livebook.dev) notebooks.

## Installation

Add `raster_ex_ratatui` to the dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:raster_ex_ratatui, "~> 0.1"}
  ]
end
```

### Prerequisites

- Elixir 1.17+
- ex_ratatui 0.14 or later (pixel regions: `CellSession.new/3` with `font_size:`)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## License

MIT — see [LICENSE](https://github.com/mcass19/raster_ex_ratatui/blob/main/LICENSE).
