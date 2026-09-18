# RasterExRatatui Usage Rules

RasterExRatatui renders [ExRatatui](https://hexdocs.pm/ex_ratatui) apps on pixel displays that are not terminals, such as e-ink panels and Linux framebuffers. It consumes `ExRatatui.CellSession` diffs (cells plus pixel regions) and produces packed pixels. It does not drive hardware itself: the consumer writes the bytes.

It is **not** a terminal emulator, a font renderer, or a display driver, and apps need no changes to run on it. Build the app with `use ExRatatui.App` as for a terminal; the surface runs it.

## Choosing the layer

| Use | When |
|-----|------|
| `use RasterExRatatui.Surface` | The default. A supervised process owns the app, rasterises, and calls `push/2` |
| `RasterExRatatui.Session` | The consumer already owns a process in charge of the panel: the same app server, raster, and folding, driven from that process's mailbox |
| `RasterExRatatui.Raster` directly | Rasterising payloads that come from somewhere else (a headless `CellSession`, a test) |

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
- Options merge in order `use` < `start_link` < `init/1`'s keyword. `:app`, `:size`, and `:format` are required somewhere in that chain. `rotate:` (90, 180, 270) turns the app for a panel on its side; `:size` stays physical and `push/2` does not change.
- Write patches **in list order**; a region patch may overlap earlier cell patches. `data` is row-major with no stride padding.
- Send input with `RasterExRatatui.Surface.send_event(surface, %ExRatatui.Event.Key{code: "enter", kind: "press"})`. Codes are lowercase strings and `kind` is the string `"press"`, never an atom.
- From `handle_info/2`, return `{:events, [event], state}` to forward events, `{:noreply, state}` otherwise.
- `app_opts` always carry `surface: %{size:, cell_size:, grid_size:, format:, scale:, rotate:}` (the panel in pixels, the effective cell, the grid in cells). Read it in `mount/1` or the reducer's `init/1` to lay the app out for its panel; never hardcode the cell size.
- `on_app_exit: :stop` (default) makes the surface exit when the app exits (same reason); `on_app_exit: :restart` starts the app again on the same surface at once. Put the surface under a supervisor either way; do not restart the app by hand inside it. Both emit `[:raster_ex_ratatui, :app, :exit]` with `:reason` and `:action`.
- `min_interval:` (ms) throttles pushes for slow panels. The surface never builds a backlog: every render waiting when it gets to work is folded into one `Raster.apply/2` call (it takes a list) and one push, so slow panels or big regions show fewer frames, never later ones. `[:raster_ex_ratatui, :frame, :raster]` reports `:diffs` per batch.
- The generated child spec is `restart: :transient`: an app that quits with `{:stop, state}` stays stopped, a crash restarts. A kiosk that must always come back uses `on_app_exit: :restart`.
- `shutdown_timeout:` (default 4000 ms) bounds how long the surface waits for the app server to stop; keep it below the supervisor's shutdown so the consumer's `terminate/2` runs.

## Sessions

```elixir
Process.flag(:trap_exit, true)
raster = RasterExRatatui.Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono)
{:ok, session} = RasterExRatatui.Session.start(raster, app: MyDevice.App, keep_frame: true)
{:render, _patches, session} = RasterExRatatui.Session.await(session)
frame = RasterExRatatui.Session.frame(session)
```

- **Trap exits before `start/2`**: the app server is linked to the caller. Its exit then reaches `handle/2` as `{:exit, reason, session}`; without trapping it takes the caller down.
- Pass **every** message the process receives to `handle/2`; it returns `{:render, patches, session}`, `{:exit, reason, session}`, or `:unknown`. Keep the returned session: it holds the folded raster.
- `handle/2` already drains every render of the session waiting in the mailbox and folds them into one call; do not build a queue on top of it. Patches may be empty when a render changed nothing.
- `keep_frame: true` keeps `frame/1` current at no cost per call; without it `frame/1` renders the raster.
- After `{:exit, _, _}` the cell session is closed and `send_event/2` is a no-op. To bring the app back, `start/2` again on `raster(session)`; the first render repaints everything. `stop/1` is safe either way.
- `stop/1` unlinks, stops the app (killing it after `shutdown_timeout:`), and closes the cell session; call it from `terminate/2`.

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
- `rotate: 90 | 180 | 270` turns the app's image clockwise on the panel. `:size` is **always the physical panel**; the grid, `logical_size/1`, and `margin/1` follow the turned image, while patches, `frame/1`, and `resize/2` stay physical. Never swap `:size` by hand to rotate.
- `new/1` raises `ArgumentError` (never `KeyError`) for a missing `:size` or `:format`, a `:size` that is not two positive integers, a bad `:scale`, or a panel too small for one cell.

## Formats and palettes

- `Mono` (gray8, 1-bit panels), `RGB565` (little-endian), `XRGB8888` (little-endian, bytes b, g, r, 255).
- Colour formats take palette options in `format_opts:` — `:reset_fg`, `:reset_bg`, `:theme` (a partial map of named colours), `:bold_bright`. `Mono` takes `:ink_max`, `:paper_min`.
- For a Linux framebuffer, pick the format from the device: `{:ok, format} = RasterExRatatui.Framebuffer.format_for(info)`. Do not assume 32 bpp.

## Fonts

- The default font is `RasterExRatatui.Font.Default6x8` (printable ASCII, light box drawing plus every `Block` border type, blocks, braille, eighths, quadrants, a few arrows and marks). Other characters render as a hatched placeholder.
- A font is a module implementing `RasterExRatatui.Font`: `cell_size/0` and `glyph/1` returning exactly `width * height` bits. Build glyphs at compile time with `RasterExRatatui.Font.Art.parse/3` and `RasterExRatatui.Font.Generated`.

## Device helpers

- `RasterExRatatui.Framebuffer.open(name)` takes the device name (`"fb0"`), not a path. `write/2` accepts patches or `{:frame, binary}` and handles stride.
- `RasterExRatatui.Input.Evdev` is pure: keep the returned keyboard struct between calls, since it tracks held modifiers and caps lock. The library does not depend on `input_event`; the consumer does.
- A complete framebuffer surface (geometry, format and scale from sysfs, a hot-pluggable evdev keyboard, host tests against a fake sysfs) is the [`rpi_framebuffer`](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples/rpi_framebuffer) example; start from it rather than from scratch. A device that already owns its display from one process uses `RasterExRatatui.Session` from that process instead, the shape of the [`e_ink`](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples/e_ink) example.

## Testing

- Test surfaces on the host: a test `push/2` sends patches to the test process, and `RasterExRatatui.Surface.raster/1` + `RasterExRatatui.Raster.frame/1` show the panel.
- Test rasterisation with a real headless `ExRatatui.CellSession` (`draw/2` + `take_cells_diff/1`); no TTY or device is involved.
