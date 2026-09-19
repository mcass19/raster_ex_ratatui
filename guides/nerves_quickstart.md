# Nerves Quick Start

From `mix nerves.new` to an ExRatatui app on a Raspberry Pi's display, with a USB keyboard and the touch panel. The same steps fit any Nerves target whose display is a Linux framebuffer. The [`rpi_framebuffer`](https://github.com/mcass19/raster_ex_ratatui/tree/main/examples/rpi_framebuffer) example is this guide, built.

## The project

```sh
mix nerves.new my_device
```

Two dependencies in `mix.exs`. `input_event` reads the keyboard and the touch panel; it is a C port that only builds on Linux, so it is the project's dependency, not the library's.

```elixir
{:raster_ex_ratatui, "~> 0.2"},
{:input_event, "~> 1.4", targets: @all_targets}
```

The app is a plain `use ExRatatui.App` module, built and tried in a terminal on the host first. On the panel it runs through a surface:

```elixir
defmodule MyDevice.Surface do
  use RasterExRatatui.Framebuffer.Surface, app: MyDevice.Dashboard
end
```

The surface only belongs on the device, so the application starts it when the target config has an entry for it:

```elixir
def start(_type, _args) do
  children =
    case Application.fetch_env(:my_device, MyDevice.Surface) do
      {:ok, opts} -> [{MyDevice.Surface, Keyword.put_new(opts, :name, MyDevice.Surface)}]
      :error -> []
    end

  Supervisor.start_link(children, strategy: :one_for_one, name: MyDevice.Supervisor)
end
```

And in `config/target.exs`:

```elixir
config :my_device, MyDevice.Surface, rotate: 90, touch: true

# IEx on the serial port instead of the panel; the surface detaches the kernel's console itself.
config :nerves, :erlinit, ctty: "ttyS0"
```

Nothing there describes the panel: its size and depth are read from sysfs at boot, the pixel format and font scale follow from them. The option table is in `RasterExRatatui.Framebuffer.Surface`.

## Build and burn

```sh
export MIX_TARGET=rpi4
mix deps.get
mix firmware
mix burn               # the first time; later: mix upload nerves.local
```

Three things get in the way:

- **The Elixir must be built for the system's OTP.** `elixir --version` says "compiled with Erlang/OTP N", and N must be the OTP major of the Nerves system (28 for `nerves_system_rpi4` 2.0.x). A version manager's plain `elixir 1.x` is often an older-OTP build; with mise, `mise use erlang@28 elixir@1.19.4-otp-28` in the project, then `mix local.hex`, `mix local.rebar`, and `mix archive.install hex nerves_bootstrap` for that install.
- **The host's ex_ratatui NIF.** A host build (`mix test`, `iex -S mix`) downloads the laptop's NIF into `deps/ex_ratatui/priv/native/`, and `mix firmware` then stops in `scrub-otp-release` with "Unexpected executable format". Delete the `x86_64` (or `aarch64-apple-darwin`) `.so` there before building firmware. The other way round, host tests that fail with "Failed to load NIF library" after a firmware build get it back with `MIX_ENV=test mix deps.compile ex_ratatui --force`.
- **`EX_RATATUI_BUILD`** set in the shell builds the NIF from source for the host; unset it for firmware builds.

## A panel on its side, and touch

`/dev/fb0` always has the panel's native orientation. `rotate: 90` (or `270`, whichever puts the text the right way up) turns the app; touch follows the rotation by itself. If taps land mirrored or on the wrong axis, `invert_x: true`, `invert_y: true`, or `swap_xy: true` in the same config fix it.

## First checks over SSH

```elixir
RasterExRatatui.Framebuffer.info("fb0")
#=> {:ok, %{width: 720, height: 1280, bits_per_pixel: 16, stride: 1440}}

# Paint it red (16 bits per pixel; at 32 use <<0, 0, 255, 255>>)
File.write!("/dev/fb0", :binary.copy(<<0x00, 0xF8>>, 720 * 1280))

InputEvent.enumerate()
RingLogger.next()
RasterExRatatui.Telemetry.probe(MyDevice.Surface, 10)
```

The surface logs the geometry, format, and scale it chose, and each input device it reads. The probe says whether the panel keeps up: `raster` plus `push` bounds the frame rate, and a mailbox that grows means the surface is falling behind.

## When it does not work

- **The panel stays dark, SSH works, and the log shows `{:framebuffer, {:enoent, ...}}`.** No framebuffer appeared within `framebuffer_timeout:`. The Raspberry Pi Touch Display 2 does not come up on the 2.1.x Pi systems: their kernel lacks `CONFIG_BACKLIGHT_PWM`, which its overlay needs since Linux 6.18. Stay on `~> 2.0.0` for it; HDMI is not affected.
- **A cursor or boot text over the app.** The console unbind failed or the framebuffer console is not `vtcon1`: `cat /sys/class/vtconsole/*/name` tells which one is the "frame buffer device", and `console:` takes its name.
- **No keys.** `InputEvent.enumerate/0` should list a device whose `:ev_key` report includes `:key_a`. Wireless keyboards behind a receiver can show up as several devices; the surface takes the first that matches, and `keyboard: "/dev/input/eventN"` picks one.
- **A 3D object or an image turns slowly.** A pixel region costs time per pixel every time it changes, about twice as much on a rotated panel. A slower animation tick or a smaller region is the fix; `Telemetry.probe/3` shows the cost.
- **`Under-voltage detected` in `dmesg`.** A Pi with a display draws more than a laptop's USB port gives; use a wall supply.

## When the defaults do not fit

Each of `init/1`, `push/2`, `handle_info/2`, and `terminate/2` can be overridden and call the default ([Linux Framebuffers](framebuffer.md)). A panel that is not a framebuffer gets its own surface ([Building a Surface](surfaces.md)), and a device that already has a process in charge of its display runs a `RasterExRatatui.Session` from it.
