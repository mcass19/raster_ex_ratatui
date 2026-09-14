# Linux Framebuffers

A Linux framebuffer exposes a display as a file: `/dev/fb0` holds the pixels and `/sys/class/graphics/fb0` describes them, so no driver code is needed on the Elixir side. `RasterExRatatui.Framebuffer` reads that geometry and writes patches to the device, and `RasterExRatatui.Input.Evdev` turns keyboard events into the key structs an ExRatatui app expects. This guide wires both into a surface.

> #### Status {: .info}
>
> Both helpers are tested against a fake sysfs, a regular file standing in for `/dev/fb0`, and synthetic key events. They have not run on a device yet. The first hardware planned for them is a Raspberry Pi 4 with the official Touch Display 2, and this guide will gain the device-specific notes from that run.

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

The depth is whatever the kernel chose, so read `bits_per_pixel` instead of assuming it. `RasterExRatatui.Framebuffer.format_for/1` maps 16 to `RGB565` and 32 to `XRGB8888`, and returns `{:error, :unsupported}` for anything else.

## The surface

A sketch of a surface for `/dev/fb0` with a keyboard read through [`input_event`](https://hex.pm/packages/input_event) (a dependency of the consumer, not of this library):

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

A keyboard plugged in after boot gets a new event device; a small process that polls `InputEvent.enumerate/0` and starts readers covers hot-plugging.

## Performance

The surface pushes patches, so the steady-state cost follows what changed rather than the size of the panel. Pixel regions are the heaviest thing on screen: their cost grows with the panel pixels they cover, so an animated `Viewport3D` is cheaper in a moderate rect or rendered less often. ex_ratatui caps region bitmaps at 1280 px on the long side, and the raster scales them nearest-neighbour onto larger rects.

## Panels without a framebuffer

The helpers assume only `/dev/fbN` and sysfs. A panel the kernel does not expose as a framebuffer (an SPI controller driven from Elixir, an e-ink driver) implements `push/2` with its own write instead; see [Building a Surface](surfaces.md).
