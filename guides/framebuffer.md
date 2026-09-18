# Linux Framebuffers

A Linux framebuffer exposes a display as a file: `/dev/fb0` holds the pixels and `/sys/class/graphics/fb0` describes them, so no driver code is needed on the Elixir side. `RasterExRatatui.Framebuffer.Surface` is a complete surface for one, keyboard included; `RasterExRatatui.Framebuffer` and `RasterExRatatui.Input.Devices` are the pieces it is made of. This guide covers the device side of both.

> #### Status {: .info}
>
> Both helpers are tested against a fake sysfs, a regular file standing in for `/dev/fb0`, and synthetic key events, and run on hardware in the [`rpi_framebuffer`](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples/rpi_framebuffer) example: a Raspberry Pi 4 with the official Touch Display 2 (`vc4drmfb`, 720×1280, 16 bits per pixel, stride 1440) on a Nerves 2.0.x system. The device notes below come from that run.

## Check the device first

Before writing a surface, confirm the framebuffer exists and read its geometry, from an IEx session on the device:

```elixir
File.ls!("/dev") |> Enum.filter(&String.starts_with?(&1, "fb"))
{:ok, info} = RasterExRatatui.Framebuffer.info("fb0")
#=> {:ok, %{width: ..., height: ..., bits_per_pixel: ..., stride: ...}}
```

Then paint it red to prove the path end to end. At 32 bits per pixel:

```elixir
File.write!("/dev/fb0", :binary.copy(<<0, 0, 255, 255>>, info.width * info.height))
```

and at 16 (`<<0, 248>>` is red in little-endian RGB565):

```elixir
File.write!("/dev/fb0", :binary.copy(<<0, 248>>, info.width * info.height))
```

A write longer than the device fails with `:enospc` after painting what fits, which is what painting 32-bit pixels on a 16-bit framebuffer looks like.

The depth is whatever the kernel chose, so read `bits_per_pixel` instead of assuming it. The KMS fbdev emulation on a Raspberry Pi gives the DSI Touch Display 2 16 bits per pixel. `RasterExRatatui.Framebuffer.format_for/1` maps 16 to `RGB565` and 32 to `XRGB8888`, and returns `{:error, :unsupported}` for anything else.

## The surface

```elixir
defmodule MyDevice.Surface do
  use RasterExRatatui.Framebuffer.Surface, app: MyDevice.Dashboard
end
```

`RasterExRatatui.Framebuffer.Surface` is the whole thing: it waits for `/dev/fb0` (the display drivers are kernel modules that load during boot; on the Pi 4 the DSI panel probed about ten seconds after the application started), reads the geometry, picks `RGB565` or `XRGB8888` from the depth and a font scale that keeps about a hundred columns on the long side, detaches the framebuffer console, reads the keyboard through `RasterExRatatui.Input.Devices`, and starts the app again when it quits. Its moduledoc has the option table: `framebuffer:`, `scale:`, `rotate:`, `console:`, `keyboard:`, and the rest.

### Under the hood

The `use` gives the module `init/1`, `push/2`, `handle_info/2`, and `terminate/2` delegating to `RasterExRatatui.Framebuffer.Surface`'s functions of the same name, and every one is overridable: an override calls the default and adds to it. The state is a map with `:fb`, the open `RasterExRatatui.Framebuffer`, and `:devices`, the `RasterExRatatui.Input.Devices`.

```elixir
@impl true
def init(opts) do
  {:ok, config, state} = RasterExRatatui.Framebuffer.Surface.init(opts)
  {:ok, config, Map.put(state, :backlight, MyDevice.Backlight.on!())}
end
```

Underneath, `Framebuffer.open/2` reads `virtual_size`, `bits_per_pixel`, and `stride` from sysfs and opens the device; `Framebuffer.write/2` places every patch row at `y * stride + x * bytes_per_pixel`, so line padding (a stride longer than the visible line) is handled, and a full frame is written the same way. A surface for a panel that is not a framebuffer uses those pieces from a `RasterExRatatui.Surface` of its own.

## A panel on its side

A framebuffer has the panel's native orientation whatever the stand does: the Touch Display 2 is 720×1280 portrait on a landscape stand. The kernel can turn its own console (`video=DSI-1:720x1280@60,rotate=90` on the command line, or fbcon's `rotate_all`), but that never changes what a write to `/dev/fb0` means; the device stays portrait. Turning the app is the raster's job: `rotate: 90` (or `270`, whichever way the stand holds it) on the surface gives the app a 1280×720 image and writes the panel in its native order, so nothing about the framebuffer side changes. See "Rotation" in [Building a Surface](surfaces.md).

## Keep the console off the display

The kernel's framebuffer console draws on the same device, so boot messages, a login prompt, or a blinking cursor can appear on top of the app.

- **Unbind fbcon.** `RasterExRatatui.Framebuffer.unbind_console/2` writes `0` to `/sys/class/vtconsole/<console>/bind`, which stops the console drawing on the framebuffer. The framebuffer console is usually `"vtcon1"`; `/sys/class/vtconsole/*/name` tells them apart. It is best effort: on a kernel without that console it returns an error that can be ignored.
- **Move the system console elsewhere.** On Nerves, erlinit's `ctty` option (`config :nerves, :erlinit, ctty: "ttyS0"`) puts IEx on a serial port instead of the display; it stays reachable over SSH.

## The keyboard

`RasterExRatatui.Input.Devices` owns the keyboard: it finds the first `/dev/input/eventN` that reports letter keys (or reads the path it is given), starts an [`input_event`](https://hex.pm/packages/input_event) reader on it with `grab: true` so keystrokes do not also reach the kernel console, translates what the reader delivers through `RasterExRatatui.Input.Evdev` into the same `%ExRatatui.Event.Key{}` structs a terminal would send (shift, ctrl, alt, super, and caps lock tracked; other layouts a `layout:` map away), and keeps looking, every two seconds, whenever there is no keyboard: at boot before one is plugged in, and again after one is unplugged, starting from a fresh translator so modifiers held on the old keyboard do not stick. The framebuffer surface embeds it; a surface of its own does the same in three lines: `Devices.new/1` + `Devices.start/1` in `init/1`, every message through `Devices.handle_info/2`, `Devices.stop/1` in `terminate/2` so no reader outlives the surface holding the grab.

`input_event` is a C port that only builds on Linux, so it is the consumer's dependency, not this library's: add `{:input_event, "~> 1.4"}` to the project. Without it `Devices.start/1` returns `{:error, :input_event_missing}` and the framebuffer surface logs a warning once and runs without input, so the project still compiles and tests on a host. One thing to know about `input_event`: `InputEvent.enumerate/0` starts and stops a short-lived reader per device from the calling process, so a surface, which traps exits, sees their `:normal` exits in `handle_info/2`; `Devices.handle_info/2` answers `:unknown` to those and the surface ignores them.

## Touch

`touch: true` on the framebuffer surface reads the first touch panel `RasterExRatatui.Input.Devices` finds (a device reporting the multitouch `abs_mt_position_x` axis, or `abs_x` with `btn_touch`), grabbed like the keyboard. `RasterExRatatui.Input.Touch` turns the first finger into the `ExRatatui.Event.Mouse` events a terminal would send: `"down"` and `"up"` on the cell under it, `"drag"` when it moves into another cell, nothing while it is in the margins; a second finger is ignored. The controller's axes are read from the device and scaled to the panel's pixels, and the cell comes from `RasterExRatatui.Raster.cell_at/2`, so a rotated panel maps right without anything else. A controller whose axes do not follow the panel's orientation gets `swap_xy:`, `invert_x:`, or `invert_y:`.

## Performance

The surface pushes patches, so the steady-state cost follows what changed rather than the size of the panel. Pixel regions are the exception, since their cost grows with the panel pixels they cover (see [Pixel Formats](pixel_formats.md#writing-a-format)): an animated `Viewport3D` is cheaper in a moderate rect or rendered less often. Only regions that changed are rasterised, so a still `Image` beside the animation costs nothing after its first frame. On the Pi 4, a 696×480 `Viewport3D` region turning five times a second costs about 43 ms to rasterise and 13 ms to write at RGB565, and the surface's mailbox stays empty; `RasterExRatatui.Telemetry.probe/3` prints those numbers for any surface.

## Panels without a framebuffer

The helpers assume only `/dev/fbN` and sysfs. A panel the kernel does not expose as a framebuffer (an SPI controller driven from Elixir, an e-ink driver) implements `push/2` with its own write instead; see [Building a Surface](surfaces.md).
