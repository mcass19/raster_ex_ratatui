# Building a Surface

A surface is the piece that puts an ExRatatui app on one particular display. It knows three things about the panel: how big it is, how its pixels are packed, and how bytes reach it. Everything between the app and those bytes (starting the app, folding cell diffs, rasterising glyphs and pixel regions, forwarding input) is done by `RasterExRatatui.Surface`.

This guide builds a surface from scratch, then looks at the two consumers the library was designed against: the Goatmire name badge (a 1-bit e-ink panel) and a Raspberry Pi 4 driving an HDMI monitor.

## The data flow

```
ExRatatui app ─ render ─▶ ExRatatui.Server ─ cell writer ─▶ %CellSession.Diff{ops, regions}
                                                                     │
                      Surface process: Raster.apply/2 ◀──────────────┘
                                                                     │
                                          [%Patch{}] ─▶ push/2 ─▶ the panel
panel input ─▶ consumer code ─▶ Surface.send_event/2 ─▶ {:ex_ratatui_event, event}
```

The app does not know it is on a panel. It renders widgets exactly as it would in a terminal; a `Viewport3D` that uses the Kitty protocol in a terminal arrives here as an RGB bitmap and is painted at the panel's native resolution.

## A minimal surface

A surface module `use`s `RasterExRatatui.Surface` and implements `c:RasterExRatatui.Surface.push/2`. Options that are known up front go in the `use` call:

```elixir
defmodule Kiosk.Surface do
  use RasterExRatatui.Surface,
    app: Kiosk.Dashboard,
    format: RasterExRatatui.PixelFormat.RGB565,
    scale: 2

  @impl true
  def init(opts) do
    {:ok, lcd} = Kiosk.LCD.open(Keyword.fetch!(opts, :spi_bus))
    {:ok, [size: Kiosk.LCD.size(lcd)], lcd}
  end

  @impl true
  def push(patches, lcd) do
    for patch <- patches do
      :ok = Kiosk.LCD.write_window(lcd, patch.x, patch.y, patch.width, patch.height, patch.data)
    end

    lcd
  end
end
```

And in the application's supervision tree:

```elixir
children = [{Kiosk.Surface, spi_bus: "spidev0.0"}]
```

`c:RasterExRatatui.Surface.init/1` receives every option (from `use` and from the child spec) and returns the ones it could only learn at runtime, here the panel size read from the driver. Unknown options, such as `:spi_bus`, pass through untouched. The state it returns is threaded through `push/2`.

## Choosing font, scale, and format

The grid is the panel size divided by the effective cell, which is the font's cell times `:scale`:

| Panel | Font × scale | Cell | Grid |
| ----- | ------------ | ---- | ---- |
| 400×300 e-ink | 6×8 × 1 | 6×8 | 66×37 |
| 480×320 SPI LCD | 6×8 × 1 | 6×8 | 80×40 |
| 720×1280 DSI panel | 6×8 × 3 | 18×24 | 40×53 |
| 1920×1080 HDMI | 6×8 × 3 | 18×24 | 106×45 |

`RasterExRatatui.Raster.grid_size/1` and `RasterExRatatui.Raster.font_size/1` report both; the surface creates the `ExRatatui.CellSession` with them, so pixel-mode widgets render bitmaps sized for the panel. See [Fonts](fonts.md) for bringing a different font and [Pixel Formats](pixel_formats.md) for the formats and palettes.

## Patches or frames

By default `push/2` receives a list of `RasterExRatatui.Patch` rectangles: one per run of changed cells on a row, one per pixel region when the region list changed, and the whole panel on the first render and after a resize. Writing them in order keeps the panel identical to `RasterExRatatui.Raster.frame/1`. Most displays can write a window (SPI LCD controllers have a "set address window" command; a framebuffer is a file with offsets), and patches keep the per-frame cost proportional to what changed.

Some panels only take whole frames: an e-ink controller that refreshes the entire panel, or a driver that expects a PNG. Set `push_mode: :frame` and `push/2` receives `{:frame, binary}` instead.

## Slow panels

An e-ink refresh can take a second. `min_interval: 1_000` makes the surface push at most once per second: renders that arrive sooner are still rasterised (the raster must see every diff), and their patches are pushed together when the interval has passed. The app is never slowed down; it keeps rendering at its own pace.

Without `min_interval` the surface still never falls behind a slow device: while `push/2` is busy, new renders are rasterised as they arrive and all of them go out in the next push, so a panel that takes 200 ms per write simply shows fewer, larger updates instead of an ever-growing queue.

## Input

The surface does not read devices. Whatever does (an evdev keyboard, GPIO buttons, a touch controller) turns its events into `ExRatatui.Event` structs and sends them with `RasterExRatatui.Surface.send_event/2`:

```elixir
RasterExRatatui.Surface.send_event(Kiosk.Surface, %ExRatatui.Event.Key{code: "down", kind: "press"})
```

When the reader delivers its messages to the surface process itself (a process started in `init/1`), `c:RasterExRatatui.Surface.handle_info/2` translates them and returns `{:events, events, state}`. `RasterExRatatui.Input.Evdev` does the translation for keyboards; see [Linux Framebuffers](framebuffer.md) for the full keyboard setup.

Key codes must match what a terminal would send (lowercase strings, `kind: "press"`), because apps pattern-match on them.

## Crashes and restarts

The surface process links to the app server. If the app crashes, the surface exits with the same reason and its supervisor restarts it, which starts a fresh app and repaints the panel. The generated child spec is `restart: :transient`, as for `ExRatatui.App`, so an app that quits with `{:stop, state}` stays stopped; a kiosk that must always come back overrides `child_spec/1` with `restart: :permanent`. If the surface stops, it stops the app first, waiting up to `:shutdown_timeout` (4 seconds by default) for the app's own `terminate/2` before killing it, so the surface's `c:RasterExRatatui.Surface.terminate/2` still runs within a supervisor's default shutdown budget. There is no crash screen by default; a consumer that wants one (the badge shows a static frame) can trap the exit in its own process and draw it.

Processes started in `init/1` with `start_link` are linked to the surface, and since the surface traps exits their `{:EXIT, pid, reason}` messages arrive in `handle_info/2`; handle them there.

## Resizing

`RasterExRatatui.Surface.resize/2` changes the panel size (an HDMI monitor hot-plugged at another resolution). The raster and the session are rebuilt, the app receives an `ExRatatui.Event.Resize`, and the next render repaints the whole panel.

## Testing a surface

Everything runs on the host: a surface whose `push/2` sends patches to the test process drives the real app, and `RasterExRatatui.Surface.raster/1` returns the raster, so `RasterExRatatui.Raster.frame/1` shows exactly what the panel would.

```elixir
test "the dashboard shows the title" do
  {:ok, surface} = Kiosk.TestSurface.start_link(test_pid: self(), size: {240, 160})
  assert_receive {:pushed, _patches}

  frame = surface |> RasterExRatatui.Surface.raster() |> RasterExRatatui.Raster.frame()
  # assert on pixels, or compare against a stored frame
end
```

## Worked example: the name badge

The badge already owns a screen process (it navigates between apps and shows a crash frame), so it uses the pure core instead of the surface process: it creates the session with `Raster.font_size/1`, starts the app server with a writer that sends diffs to its screen, and folds them with `RasterExRatatui.Raster.apply/2`. Its 1-bit panel only refreshes whole frames, so it renders `RasterExRatatui.Raster.frame/1` with `RasterExRatatui.PixelFormat.Mono` and hands the gray8 buffer to its PNG + SPI driver. Two GPIO buttons become `%Key{}` events it sends to the server.

## Worked example: an HDMI monitor on a Raspberry Pi 4

The Pi uses the surface process: `init/1` reads the framebuffer geometry with `RasterExRatatui.Framebuffer.info/2`, picks the format with `RasterExRatatui.Framebuffer.format_for/1`, opens `/dev/fb0`, and starts an `input_event` reader for the keyboard; `push/2` is one `RasterExRatatui.Framebuffer.write/2`; `handle_info/2` runs the keyboard messages through `RasterExRatatui.Input.Evdev`. The [Linux Framebuffers guide](framebuffer.md) walks through it, and `examples/rpi4_hdmi` is the complete project.
