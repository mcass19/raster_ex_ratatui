# E-ink name badge

ExRatatui apps on a 400×300 1-bit e-ink panel: the [Goatmire name badge](https://github.com/protolux-electronics/name_badge), a Nerves device with two buttons. The code lives in a fork of the badge firmware, not in this folder:

**[mcass19/name_badge#3](https://github.com/mcass19/name_badge/pull/3)** — the pull request that adds `raster_ex_ratatui` to the badge.

This is the example for a device that **does not** run a `RasterExRatatui.Surface`. The badge already has a process per screen that owns rendering, refresh dedupe, navigation, and the back button, so it uses the pure core from inside that process. For the surface process on a framebuffer, see [`rpi_framebuffer`](../rpi_framebuffer).

## What to read in the pull request

| File | What it shows |
|------|---------------|
| `lib/name_badge/screen/ex_ratatui.ex` | The host: a badge screen that runs any `ExRatatui.App`. Everything below happens here. |
| `lib/name_badge/screen/ex_ratatui/banner.ex` | A reducer app: big blinking text that picks the largest `BigText` size that fits, and cycles polarity against e-ink ghosting. |
| `lib/name_badge/screen/ex_ratatui/showcase.ex` | A reducer app with two pixel regions on a 1-bit panel: a shaded `Viewport3D` object and a photo, both ordered-dithered by `PixelFormat.Mono`, next to BEAM sparklines made of cells. |
| `lib/name_badge/screen/banner.ex`, `showcase.ex` | The menu entries: `use NameBadge.Screen.ExRatatui, app: ...` and nothing else. |
| `test/name_badge/screen/ex_ratatui_test.exs` | The host tested on a laptop, asserting on the 400×300 frame. |

## How the host works

The raster decides the grid, and the session is created to match, with the font's cell size so pixel-mode widgets hand over bitmaps instead of half blocks:

```elixir
raster = Raster.new(size: {400, 300}, font: Default6x8, format: Mono)
{cols, rows} = Raster.grid_size(raster)                                      # {66, 37}
session = CellSession.new(cols, rows, font_size: Raster.font_size(raster))   # {6, 8}
```

The app server starts linked, on that session, with a writer that sends every diff to the screen process:

```elixir
writer = fn diff -> send(screen_pid, {:ex_ratatui_diff, diff}) end

{:ok, server} =
  ExRatatui.Transport.start_server(
    [mod: app_mod, name: nil, transport: {:cell_session, session, writer}] ++ app_opts
  )
```

The screen keeps one gray8 frame. Each diff goes through `Raster.apply/2`, and the patches that come back are blitted onto the frame:

```elixir
defp fold(raster, frame, diffs) do
  {width, _height} = Raster.size(raster)
  bytes_per_pixel = Raster.bytes_per_pixel(raster)

  Enum.reduce(diffs, {raster, frame}, fn diff, {raster, frame} ->
    {raster, patches} = Raster.apply(raster, diff)
    {raster, Enum.reduce(patches, frame, &Patch.blit(&2, width, bytes_per_pixel, &1))}
  end)
end
```

An e-ink refresh blocks the screen process for a while, so diffs queue up behind it. Before folding, the handler drains the mailbox and folds them all, and the next refresh shows the latest frame only:

```elixir
def handle_info({:ex_ratatui_diff, diff}, screen) do
  {raster, frame} = fold(screen.assigns.raster, screen.assigns.frame, [diff | drain_diffs()])
  {:noreply, screen |> assign(:raster, raster) |> assign(:frame, frame)}
end
```

The frame reaches the panel as a `Dither` image built from the raw gray8 bytes, which the badge's display code already knows how to send. There is no PNG encode on the device.

Input is two GPIO buttons. The host maps `{button, press_type}` to `%ExRatatui.Event.Key{}` structs (A is `"up"`, a long A is `"home"`, B is `"down"`) and sends them to the server as `{:ex_ratatui_event, key}`. A long B never reaches the app: the badge's own screen behaviour uses it to go back to the menu.

The host traps exits. When the app server crashes, the screen stays up, draws a crash frame through the same raster (a `Paragraph` on a throwaway session, folded with `Raster.apply/2`), and the back button keeps working.

## Why not a surface

A `RasterExRatatui.Surface` would be a second process whose `push/2` still had to message the screen process, which is the one allowed to talk to the display. And a surface exits when its app exits, which is right under a supervisor but wrong here: the badge wants a crash frame, not a dead screen. Devices that already have a process in charge of the panel are what `RasterExRatatui.Session` is for: the app server, cell session, and raster started from that process, its renders folded with `Session.handle/2`, the kept frame from `Session.frame/1`, the app's exit as `{:exit, reason, session}`. The badge code in the pull request predates `Session` and does the same loop by hand with `Raster.apply/2` and `Patch.blit/4`; a new consumer starts from `Session` (see "Own process" in [Building a Surface](https://hexdocs.pm/raster_ex_ratatui/surfaces.html)).

## Things specific to 1-bit panels

- `PixelFormat.Mono` produces gray8 (0 is ink, 255 is paper). Cells follow tone rules (dark colours become ink, light ones paper, the middle band a checkerboard) and pixel regions get a Bayer 4×4 ordered dither. See [Pixel Formats](https://hexdocs.pm/raster_ex_ratatui/pixel_formats.html).
- Photos need preparing: a 1-bit dither turns midtones into dot patterns, so the Showcase photos were contrast-stretched first.
- Every render is a panel refresh. The apps return `render?: false` for messages that change nothing, and tick every 2 to 3 seconds.

## Related

- [Building a Surface](https://hexdocs.pm/raster_ex_ratatui/surfaces.html) — the contract, and this badge as its worked example of the pure core.
- [`rpi_framebuffer`](../rpi_framebuffer) — the other shape: a surface process on a colour Linux framebuffer.
