# RasterExRatatui

[![Hex.pm](https://img.shields.io/hexpm/v/raster_ex_ratatui.svg)](https://hex.pm/packages/raster_ex_ratatui)
[![Docs](https://img.shields.io/badge/hex-docs-blue)](https://hexdocs.pm/raster_ex_ratatui)
[![CI](https://github.com/mcass19/raster_ex_ratatui/actions/workflows/ci.yml/badge.svg)](https://github.com/mcass19/raster_ex_ratatui/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/raster_ex_ratatui.svg)](https://github.com/mcass19/raster_ex_ratatui/blob/main/LICENSE)

Render [ExRatatui](https://github.com/mcass19/ex_ratatui) apps on pixel displays: e-ink panels, SPI LCDs, HDMI through a Linux framebuffer.

<!-- .github/demo.gif: the Goatmire badge and the rpi4 HDMI demo, added before the first release -->

A terminal paints glyphs for us. A panel with nothing but pixels does not, so something has to turn every cell (a symbol, a foreground, a background) into pixels, and blit the bitmaps that `Viewport3D` and `Image` render. `RasterExRatatui` is that something. It sits on top of an `ExRatatui.CellSession`, keeps the cell grid and the pixel regions of the current frame, and hands the device only the rectangles that changed, already packed in the panel's pixel format.

```
ExRatatui app ──> ExRatatui.Server ──> CellSession diff (cells + regions)
                                              │
                         RasterExRatatui.Raster  (font × palette × pixel format × scale)
                                              │
                         [%Patch{x, y, width, height, data}]
                                              │
                         Surface.push/2 ──> e-ink / LCD / /dev/fb0
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

`MyDevice.App` is any `ExRatatui.App`, unchanged. Add `MyDevice.Surface` to a supervision tree and the app is on the display; send it input with `RasterExRatatui.Surface.send_event/2`.

## Examples

A headless snapshot script and a Raspberry Pi 4 HDMI project live under [`examples/`](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples). See the [catalog](https://github.com/mcass19/raster_ex_ratatui/blob/main/examples/README.md).

## Guides

| Guide | Description |
|-------|-------------|
| [Building a Surface](guides/surfaces.md) | The contract: geometry, push, input, crashes, testing, and the two worked examples |
| [Fonts](guides/fonts.md) | The glyph layout, the built-in 6×8 font, scale, and bringing a font |
| [Pixel Formats](guides/pixel_formats.md) | `Mono` tone rules and dithering, colour palettes, writing a format |
| [Linux Framebuffers](guides/framebuffer.md) | A Raspberry Pi 4 on HDMI with a USB keyboard, on Nerves |
| [Telemetry](guides/telemetry.md) | Rasterisation, push, and input events with a `Telemetry.Metrics` example |
| [Cheatsheet](guides/cheatsheet.cheatmd) | Every option and call on one page |

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
- ex_ratatui with pixel regions (`CellSession.new/3` with `font_size:`)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## License

MIT — see [LICENSE](https://github.com/mcass19/raster_ex_ratatui/blob/main/LICENSE).
