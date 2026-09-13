# RasterExRatatui Usage Rules

RasterExRatatui renders [ExRatatui](https://hexdocs.pm/ex_ratatui) apps on pixel displays that are not terminals: e-ink panels, SPI LCDs, HDMI and DSI displays through a Linux framebuffer. It consumes `ExRatatui.CellSession` diffs (cells plus pixel regions) and produces packed pixels. It does not drive hardware itself: the consumer writes the bytes.

It is **not** a terminal emulator, a font renderer, or a display driver, and apps need no changes to run on it. Build the app with `use ExRatatui.App` as for a terminal; the surface runs it.

## Choosing the layer

| Use | When |
|-----|------|
| `use RasterExRatatui.Surface` | The default. A supervised process owns the app, rasterises, and calls `push/2` |
| `RasterExRatatui.Raster` directly | The consumer already owns a process and a device loop (the name badge does) |

## Surfaces

```elixir
defmodule MyDevice.Surface do
  use RasterExRatatui.Surface, app: MyDevice.App, format: RasterExRatatui.PixelFormat.RGB565, scale: 2

  @impl true
  def init(opts), do: {:ok, [size: {480, 320}], MyDevice.LCD.open!(opts)}

  @impl true
  def push(patches, lcd) do
    Enum.each(patches, &MyDevice.LCD.write(lcd, &1.x, &1.y, &1.width, &1.height, &1.data))
    lcd
  end
end
```

- `push/2` is the only required callback. It receives `[%RasterExRatatui.Patch{}]` (default) or `{:frame, binary}` with `push_mode: :frame`, and **must return the new state**, not `:ok`.
- `init/1` returns `{:ok, extra_opts, state}`: a **three**-tuple. `extra_opts` is a keyword list merged over the `use`/`start_link` options, for values known only at runtime (`:size`, `:format`).
- Options merge in order `use` < `start_link` < `init/1`'s keyword. `:app`, `:size`, and `:format` are required somewhere in that chain.
- Write patches **in list order**; a region patch may overlap earlier cell patches. `data` is row-major with no stride padding.
- Send input with `RasterExRatatui.Surface.send_event(surface, %ExRatatui.Event.Key{code: "enter", kind: "press"})`. Codes are lowercase strings and `kind` is the string `"press"`, never an atom.
- From `handle_info/2`, return `{:events, [event], state}` to forward events, `{:noreply, state}` otherwise.
- The surface exits when the app exits (same reason). Put the surface under a supervisor; do not try to restart the app inside it.
- `min_interval:` (ms) throttles pushes for slow panels; renders are still rasterised in between. A slow `push/2` never builds a backlog: renders that arrive during a push are pushed together in the next call.
- The generated child spec is `restart: :transient`: an app that quits with `{:stop, state}` stays stopped, a crash restarts. Override `child_spec/1` for a kiosk that must always come back.
- `shutdown_timeout:` (default 4000 ms) bounds how long the surface waits for the app server to stop; keep it below the supervisor's shutdown so the consumer's `terminate/2` runs.

## Raster

```elixir
raster = RasterExRatatui.Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono)
{cols, rows} = RasterExRatatui.Raster.grid_size(raster)
session = ExRatatui.CellSession.new(cols, rows, font_size: RasterExRatatui.Raster.font_size(raster))
{raster, patches} = RasterExRatatui.Raster.apply(raster, ExRatatui.CellSession.take_cells_diff(session))
frame = RasterExRatatui.Raster.frame(raster)
```

- Always create the session with `grid_size/1` and `font_size:` from the **same raster**. Without `font_size:`, `Viewport3D` and `Image` degrade to half blocks and no regions arrive.
- `Raster` is an immutable value: keep the struct `apply/2` returns, or the next diff is folded into a stale grid.
- Feed **every** diff to `apply/2`, in order, even when not pushing; diffs are deltas.
- `:scale` is a positive integer; the effective cell is font cell × scale.

## Formats and palettes

- `Mono` (gray8, 1-bit panels), `RGB565` (little-endian), `XRGB8888` (little-endian, bytes b, g, r, 255).
- Colour formats take palette options in `format_opts:` — `:reset_fg`, `:reset_bg`, `:theme` (a partial map of named colours), `:bold_bright`. `Mono` takes `:ink_max`, `:paper_min`.
- For a Linux framebuffer, pick the format from the device: `{:ok, format} = RasterExRatatui.Framebuffer.format_for(info)`. Do not assume 32 bpp.

## Fonts

- The default font is `RasterExRatatui.Font.Default6x8` (ASCII, light box drawing, blocks, braille, eighths, quadrants). Other characters render as a hatched placeholder.
- A font is a module implementing `RasterExRatatui.Font`: `cell_size/0` and `glyph/1` returning exactly `width * height` bits. Build glyphs at compile time with `RasterExRatatui.Font.Art.parse/3` and `RasterExRatatui.Font.Generated`.

## Device helpers

- `RasterExRatatui.Framebuffer.open(name)` takes the device name (`"fb0"`), not a path. `write/2` accepts patches or `{:frame, binary}` and handles stride.
- `RasterExRatatui.Input.Evdev` is pure: keep the returned keyboard struct between calls, since it tracks held modifiers and caps lock. The library does not depend on `input_event`; the consumer does.

## Testing

- Test surfaces on the host: a test `push/2` sends patches to the test process, and `RasterExRatatui.Surface.raster/1` + `RasterExRatatui.Raster.frame/1` show the panel.
- Test rasterisation with a real headless `ExRatatui.CellSession` (`draw/2` + `take_cells_diff/1`); no TTY or device is involved.
