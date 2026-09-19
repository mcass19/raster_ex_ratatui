# Building a Surface

A surface is the piece that puts an ExRatatui app on one particular display. It knows three things about the panel: how big it is, how its pixels are packed, and how bytes reach it. Everything between the app and those bytes (starting the app, folding cell diffs, rasterising glyphs and pixel regions, forwarding input) is done by `RasterExRatatui.Surface`.

This guide builds a surface from scratch, then shows the same machinery driven from a process the consumer already owns (`RasterExRatatui.Session`), with a 1-bit e-ink name badge as the worked example.

## The data flow

```
ExRatatui app ─ render ──> ExRatatui.Server ─ cell writer ──> %CellSession.Diff{ops, regions}
                                                                      │
                      Surface process: Raster.apply/2 <───────────────┘
                                                                      │
                                          [%Patch{}] ──> push/2 ──> the panel
panel input ──> consumer code ──> Surface.send_event/2 ──> {:ex_ratatui_event, event}
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

The app, for its part, learns about the panel from its own options: the surface adds `surface:` to `app_opts`, a map with the panel `:size` in pixels, the effective `:cell_size`, the `:grid_size` in cells, the `:format`, the `:scale`, and the `:rotate` angle. An app that lays itself out differently on a small panel, or that needs the pixel size of a cell to size a pixel region, reads it in `mount/1` (or the reducer's `init/1`).

## Choosing font, scale, and format

The grid is the panel size divided by the effective cell, which is the font's cell times `:scale`. For a few panel sizes:

| Panel size | Font × scale | Cell | Grid |
| ---------- | ------------ | ---- | ---- |
| 400×300 (a small e-ink panel) | 6×8 × 1 | 6×8 | 66×37 |
| 480×320 | 6×8 × 1 | 6×8 | 80×40 |
| 720×1280 | 6×8 × 3 | 18×24 | 40×53 |
| 1920×1080 | 6×8 × 3 | 18×24 | 106×45 |

`RasterExRatatui.Raster.grid_size/1` and `RasterExRatatui.Raster.font_size/1` report both; the surface creates the `ExRatatui.CellSession` with them, so pixel-mode widgets render bitmaps sized for the panel. See [Fonts](fonts.md) for bringing a different font and [Pixel Formats](pixel_formats.md) for the formats and palettes.

## Patches or frames

By default `push/2` receives a list of `RasterExRatatui.Patch` rectangles: one per run of changed cells on a row, one per pixel region that is new or changed, and the whole panel on the first render and after a resize. Writing them in order keeps the panel identical to `RasterExRatatui.Raster.frame/1`. Most displays can write a window (SPI LCD controllers have a "set address window" command; a framebuffer is a file with offsets), and patches keep the per-frame cost proportional to what changed.

Some panels only take whole frames: an e-ink controller that refreshes the entire panel, or a driver that expects a PNG. Set `push_mode: :frame` and `push/2` receives `{:frame, binary}` instead.

## Slow panels

An e-ink refresh can take a second. `min_interval: 1_000` makes the surface push at most once per second: renders that arrive sooner wait, then go through the raster together and out in one push when the interval has passed. The app is never slowed down; it keeps rendering at its own pace.

Without `min_interval` the surface still never falls behind a slow device or a slow raster. Whenever it gets to work, every render waiting in its mailbox is folded into the raster as one batch (`RasterExRatatui.Raster.apply/2` takes a list) and pushed at once, so a cell or region that changed five times is drawn in its final state only. A panel that takes 200 ms per write, or a pixel region that takes 200 ms to rasterise, shows fewer, later frames instead of an ever-growing queue, and a key press never waits behind stale animation frames. The `[:raster_ex_ratatui, :frame, :raster]` telemetry event reports how many diffs each batch folded; a steady count above 1 means the app renders faster than the surface can show, which is fine, and where a slower tick or a smaller region pays off.

## Input

The surface does not read devices. Whatever does (an evdev keyboard, GPIO buttons, a touch controller) turns its events into `ExRatatui.Event` structs and sends them with `RasterExRatatui.Surface.send_event/2`:

```elixir
RasterExRatatui.Surface.send_event(Kiosk.Surface, %ExRatatui.Event.Key{code: "down", kind: "press"})
```

When the reader delivers its messages to the surface process itself (a process started in `init/1`), `c:RasterExRatatui.Surface.handle_info/2` translates them and returns `{:events, events, state}`. `RasterExRatatui.Input.Evdev` does the translation for keyboards; see [Linux Framebuffers](framebuffer.md) for a keyboard reader wired into a surface.

Key codes must match what a terminal would send (lowercase strings, `kind: "press"`), because apps pattern-match on them.

## Crashes and restarts

The surface process links to the app server, and `on_app_exit:` says what happens when the app exits. With the default, `:stop`, the surface exits with the same reason and its supervisor decides: the generated child spec is `restart: :transient`, as for `ExRatatui.App`, so a crash restarts the pair (a fresh app, a repainted panel) and an app that quits with `{:stop, state}` stays stopped. With `on_app_exit: :restart` the surface stays up, keeps its raster, opens a fresh cell session, and starts the app again at once; the new app's first render repaints the panel. That is the setting for a kiosk or any panel that has nothing else to show, where a `q` in the app should bring it straight back. Either way the exit is reported as `[:raster_ex_ratatui, :app, :exit]` with the reason and the action taken. If the surface stops, it stops the app first, waiting up to `:shutdown_timeout` (4 seconds by default) for the app's own `terminate/2` before killing it, so the surface's `c:RasterExRatatui.Surface.terminate/2` still runs within a supervisor's default shutdown budget. There is no crash screen by default; a consumer that wants one (a static frame, say) can trap the exit in its own process and draw it.

Processes started in `init/1` with `start_link` are linked to the surface, and since the surface traps exits their `{:EXIT, pid, reason}` messages arrive in `handle_info/2`; handle them there.

## Resizing

`RasterExRatatui.Surface.resize/2` changes the panel size (a display that comes back at another resolution). The raster and the session are rebuilt, the app receives an `ExRatatui.Event.Resize`, and the next render repaints the whole panel.

## Rotation

A panel keeps its native scan order however it is mounted: the Raspberry Pi Touch Display 2 is a 720×1280 portrait framebuffer even on a landscape stand. `rotate: 90` (or `180`, `270`, clockwise) turns the app's image on its way to the panel:

```elixir
use RasterExRatatui.Surface,
  app: Kiosk.Dashboard,
  format: RasterExRatatui.PixelFormat.RGB565,
  size: {720, 1280},
  scale: 2,
  rotate: 90
```

`:size` stays the physical panel, and so do the patches, the frame, and `push/2`: the panel driver never knows. The grid is that of the turned image (1280×720 here, 106×45 cells at scale 2 instead of 60×80), the app receives it as its width and height and as `grid_size` in `surface:`, and `RasterExRatatui.Raster.logical_size/1` reports it. Glyphs are rotated once as they enter the raster's cache, a run of cells becomes a vertical strip, and pixel regions are gathered from their bitmaps already turned, so a rotated frame costs about what a flat one does. Dithering and checkerboards stay anchored to the panel's own pixels. The [Linux Framebuffers](framebuffer.md) guide has the console side of a rotated panel.

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

To look at it, `RasterExRatatui.Raster.to_png/1` turns the raster into a PNG of the physical panel: `File.write!("panel.png", RasterExRatatui.Raster.to_png(raster))` from a test or IEx, and any image viewer shows what the device would.

## Own process: Session

Some devices already have a process in charge of the panel: a screen manager that navigates between apps, a driver loop that owns the bus. A second process whose `push/2` would only message the first is in the way there, and so is a surface that exits when its app does. `RasterExRatatui.Session` is the surface without the process: the app server, the cell session, and the raster, started from the caller and driven by the caller's mailbox.

```elixir
defmodule Kiosk.Screen do
  use GenServer

  alias RasterExRatatui.{Raster, Session}

  def init(app) do
    Process.flag(:trap_exit, true)
    raster = Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono)
    {:ok, session} = Session.start(raster, app: app, keep_frame: true)
    {:ok, session}
  end

  def handle_info(msg, session) do
    case Session.handle(session, msg) do
      {:render, _patches, session} ->
        Kiosk.Panel.show(Session.frame(session))
        {:noreply, session}

      {:exit, reason, session} ->
        Kiosk.Panel.show(crash_frame(reason))
        {:noreply, session}

      :unknown ->
        {:noreply, session}
    end
  end

  def terminate(_reason, session), do: Session.stop(session)
end
```

`Session.start/2` links the app server to the caller, which therefore traps exits; the app's exit then arrives as a message that `handle/2` turns into `{:exit, reason, session}`, and the caller decides what the panel shows. Every render of the app arrives as a `{RasterExRatatui.Session, ref, diff}` message; `handle/2` folds it, and every render of the session still waiting behind it, into the raster in one go and returns the patches, so a slow panel shows fewer, later frames and never queues up. With `keep_frame: true` the session also keeps a full frame current for panels that only take whole frames; `Session.frame/1` returns it. `Session.await/2` waits for the first render before the panel shows anything, `Session.send_event/2` forwards input, `Session.resize/2` changes the panel size, and `Session.stop/1` stops the app and closes the cell session. A consumer that wants the app back after it exits starts a new session on the same raster: the new app's first render repaints everything. The app receives the same `surface:` option a surface gives it.

`handle/2` splits in two for a consumer that gathers renders and rasterises on its own schedule: `Session.drain/2` classifies the message and gathers the waiting renders, `Session.render/2` folds a list of them.

## Worked example: an e-ink name badge

The [Goatmire name badge](https://github.com/mcass19/name_badge/pull/3), a 400×300 1-bit e-ink panel on Nerves (walked through in the [`e_ink`](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples/e_ink) example), already owns a screen process that navigates between apps, dedupes refreshes, and shows a crash frame, so it runs its ExRatatui apps from that process rather than under a surface. Its screen is the shape above: a 400×300 `Mono` session with `keep_frame: true`, the frame handed to the display as a dithered image after each `{:render, …}`, a crash frame drawn through the same raster on `{:exit, …}` instead of a dead screen, two GPIO buttons turned into `%ExRatatui.Event.Key{}` events with `Session.send_event/2`, and `Session.await/2` for the first frame so the panel never shows an empty screen. (The badge fork on hex `0.1` does the same by hand with `Raster.apply/2` and `RasterExRatatui.Patch.blit/4`; `Session` packages that loop.)
