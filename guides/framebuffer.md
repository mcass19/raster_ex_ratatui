# Linux Framebuffers

A Linux framebuffer exposes a display as a file: `/dev/fb0` holds the pixels and `/sys/class/graphics/fb0` describes them. It is the shortest path from Elixir to an HDMI monitor or a DSI panel on a Raspberry Pi, with no C driver and no compositor. `RasterExRatatui.Framebuffer` wraps it, and this guide puts an ExRatatui app on a Pi 4's HDMI output with a USB keyboard, on Nerves.

## Check the device first

Before writing any code, confirm the framebuffer exists and learn its geometry, from an IEx session on the device (over SSH):

```elixir
File.ls!("/dev") |> Enum.filter(&String.starts_with?(&1, "fb"))
RasterExRatatui.Framebuffer.info("fb0")
#=> {:ok, %{width: 1920, height: 1080, bits_per_pixel: 16, stride: 3840}}
```

Then paint it red, to prove the path end to end. For 32 bits per pixel:

```elixir
File.write!("/dev/fb0", :binary.copy(<<0, 0, 255, 255>>, 1920 * 1080))
```

and for 16 (`<<0, 248>>` is red in little-endian RGB565):

```elixir
File.write!("/dev/fb0", :binary.copy(<<0, 248>>, 1920 * 1080))
```

On a Pi with the full KMS driver (`dtoverlay=vc4-kms-v3d`, the default on current Nerves systems), `/dev/fb0` comes from DRM's fbdev emulation, and its depth is whatever the kernel chose; always read `bits_per_pixel` instead of assuming it. If the device is missing, the firmware KMS driver (`dtoverlay=vc4-fkms-v3d`) is the fallback. The geometry follows the mode the monitor negotiated at boot; the kernel command line (`video=HDMI-A-1:1280x720@60`) pins it.

## The surface

```elixir
defmodule MyDevice.HdmiSurface do
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

The kernel's framebuffer console draws on the same device, so boot messages, a login prompt, or a blinking cursor can appear on top of the app. Two things keep it away:

- **Move the Erlang console to the serial port.** Nerves Pi systems attach IEx to the HDMI console (`tty1`) by default. In `config/target.exs`: `config :nerves, :erlinit, ctty: "ttyS0"` (with `enable_uart=1` in `config.txt`). IEx stays reachable over SSH and serial.
- **Unbind fbcon.** `RasterExRatatui.Framebuffer.unbind_console/2` writes `0` to `/sys/class/vtconsole/vtcon1/bind`, which stops the console drawing on the framebuffer. It is best effort: on a kernel without a bound framebuffer console it returns an error that can be ignored.

## The keyboard

`input_event` reads `/dev/input/eventN` and delivers `{:input_event, path, events}` to the process that started it; started in the surface's `init/1`, that is the surface. `grab: true` keeps the keystrokes from also reaching the kernel console. `RasterExRatatui.Input.Evdev` keeps track of shift, ctrl, alt, super, and caps lock, and produces the same `%ExRatatui.Event.Key{}` structs a terminal would, so the app's key handling is unchanged. Layouts other than US are a `layout:` map away.

A keyboard plugged in after boot gets a new event device; a small process that polls `InputEvent.enumerate/0` and starts readers covers hot-plugging.

## Performance

On a desktop CPU a full 1080p repaint (106×45 cells at scale 3) rasterises in about 20 ms and a typical diff in well under a millisecond; a Pi 4 is several times slower, which is why the surface pushes patches rather than frames. Pixel regions cost one call per panel pixel they cover, so an animated `Viewport3D` is the heaviest thing on screen: keep its rect moderate (a quarter of the screen animates comfortably), or render it less often. Regions are capped by ex_ratatui at 1280 px on the long side and scaled nearest-neighbour onto larger rects.

## Other panels on the same path

Anything that shows up as `/dev/fbN` works the same way: the official Raspberry Pi DSI touch displays (enabled with their `dtoverlay` in `config.txt`, portrait by default), HDMI panels of any size, and SPI TFTs whose kernel driver provides a framebuffer. A panel without a kernel framebuffer (an SPI controller driven from Elixir with `Circuits.SPI`) implements `push/2` with its own window-write command instead.
