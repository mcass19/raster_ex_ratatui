# Linux Framebuffers

A Linux framebuffer exposes a display as a file: `/dev/fb0` holds the pixels and `/sys/class/graphics/fb0` describes them, so no driver code is needed on the Elixir side. `RasterExRatatui.Framebuffer` reads that geometry and writes patches to the device, and `RasterExRatatui.Input.Evdev` turns keyboard events into the key structs an ExRatatui app expects. This guide wires both into a surface.

> #### Status {: .info}
>
> Both helpers are tested against a fake sysfs, a regular file standing in for `/dev/fb0`, and synthetic key events. The device checks below have run on a Raspberry Pi 4 with the official Touch Display 2 (`vc4drmfb`, 720×1280, 16 bits per pixel, stride 1440); the helpers' own first run on that device is pending, with the [`rpi_framebuffer`](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples/rpi_framebuffer) example, and this guide will gain the notes from it.

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

A sketch of a surface for `/dev/fb0` with a keyboard read through [`input_event`](https://hex.pm/packages/input_event) (a dependency of the consumer, not of this library). The [`rpi_framebuffer`](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples/rpi_framebuffer) example is the complete version: a Nerves project with the scale derived from the panel size, a keyboard that can come and go, and tests against a fake sysfs.

```elixir
defmodule MyDevice.FramebufferSurface do
  use RasterExRatatui.Surface, app: MyDevice.Dashboard, scale: 3

  alias RasterExRatatui.Framebuffer
  alias RasterExRatatui.Input.Evdev

  @impl true
  def init(_opts) do
    {:ok, fb} = Framebuffer.open("fb0")
    {:ok, format} = Framebuffer.format_for(fb.info)
    _ = Framebuffer.unbind_console("vtcon1")

    {:ok, _reader} = InputEvent.start_link(path: keyboard_path(), grab: true)

    {:ok, [size: {fb.info.width, fb.info.height}, format: format], %{fb: fb, keyboard: Evdev.new()}}
  end

  @impl true
  def push(pixels, state) do
    :ok = Framebuffer.write(state.fb, pixels)
    state
  end

  @impl true
  def handle_info({:input_event, _path, events}, state) do
    {keyboard, keys} = Evdev.translate_all(state.keyboard, events)
    {:events, keys, %{state | keyboard: keyboard}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp keyboard_path do
    {path, _info} =
      Enum.find(InputEvent.enumerate(), fn {_path, info} ->
        Enum.any?(info.report_info, &match?({:ev_key, keys} when is_list(keys) and :key_a in keys, &1))
      end)

    path
  end
end
```

`Framebuffer.write/2` places every patch row at `y * stride + x * bytes_per_pixel`, so line padding (a stride longer than the visible line) is handled; a full frame is written the same way.

## Keep the console off the display

The kernel's framebuffer console draws on the same device, so boot messages, a login prompt, or a blinking cursor can appear on top of the app.

- **Unbind fbcon.** `RasterExRatatui.Framebuffer.unbind_console/2` writes `0` to `/sys/class/vtconsole/<console>/bind`, which stops the console drawing on the framebuffer. The framebuffer console is usually `"vtcon1"`; `/sys/class/vtconsole/*/name` tells them apart. It is best effort: on a kernel without that console it returns an error that can be ignored.
- **Move the system console elsewhere.** On Nerves, erlinit's `ctty` option (`config :nerves, :erlinit, ctty: "ttyS0"`) puts IEx on a serial port instead of the display; it stays reachable over SSH.

## The keyboard

`input_event` reads `/dev/input/eventN` and delivers `{:input_event, path, events}` to the process that started it; started in the surface's `init/1`, that is the surface. `grab: true` keeps the keystrokes from also reaching the kernel console. `RasterExRatatui.Input.Evdev` keeps track of shift, ctrl, alt, super, and caps lock, and produces the same `%ExRatatui.Event.Key{}` structs a terminal would, so the app's key handling is unchanged. Layouts other than US are a `layout:` map away.

A keyboard plugged in after boot gets a new event device. The `rpi_framebuffer` example covers it inside the surface: the reader is linked, the surface looks for a keyboard again when the reader exits and every two seconds while there is none, and it starts from a fresh `Evdev` state so modifiers held on the old keyboard do not stick.

## Performance

The surface pushes patches, so the steady-state cost follows what changed rather than the size of the panel. Pixel regions are the exception, since their cost grows with the panel pixels they cover (see [Pixel Formats](pixel_formats.md#writing-a-format)): an animated `Viewport3D` is cheaper in a moderate rect or rendered less often. Only regions that changed are rasterised, so a still `Image` beside the animation costs nothing after its first frame.

## Panels without a framebuffer

The helpers assume only `/dev/fbN` and sysfs. A panel the kernel does not expose as a framebuffer (an SPI controller driven from Elixir, an e-ink driver) implements `push/2` with its own write instead; see [Building a Surface](surfaces.md).
