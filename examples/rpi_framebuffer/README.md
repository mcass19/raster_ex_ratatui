# rpi_framebuffer

A Nerves project that puts an ExRatatui dashboard on a Raspberry Pi's display through `/dev/fb0`, with a USB keyboard. The first hardware is a Raspberry Pi 4 with the official Touch Display 2 (7", DSI, 720×1280), but nothing in the project describes a panel: size and depth are read from sysfs at boot, so an HDMI monitor or another Pi works with the same firmware.

It is the example for the **surface process**: `RpiFramebuffer.Surface` is a `RasterExRatatui.Surface` under a supervisor. For a device that keeps its own screen process and uses the pure core instead, see [`e_ink`](../e_ink).

> **Status:** the project is tested on the host against a fake sysfs and a file standing in for `/dev/fb0`. Its first run on the Pi is pending; this note goes away with the device results.

## What is on the panel

`RpiFramebuffer.Dashboard` is an ordinary `ExRatatui.App` (reducer runtime) with three tabs. It knows nothing about pixels.

| Tab | What to see |
|-----|-------------|
| **Showcase** | What a console cannot show: a lit, turning `Viewport3D` object and a colour photo as pixel regions at the panel's own resolution, next to BEAM sparklines and a gauge made of cells. `s` next object, `p` next photo, `space` pause. |
| **System** | The device from `/proc` and `/sys`: load, a bar per core, memory, SoC temperature with history, uptime, and the addresses it answers on. |
| **Input** | The keyboard arriving whole: a text input, the last key with its modifiers spelled out, the keys before it, and an echo pane (`enter` sends, `esc` clears). |

`tab` and `shift+tab` walk the tabs, `f1` to `f3` jump, `ctrl+q` quits (so does `q` outside the Input tab). Quitting restarts the dashboard: the panel has nothing else to show.

Layouts are constraints only. Panes sit side by side on a landscape grid and stack on a portrait one, so the same app holds at 60×80 cells (the Touch Display 2 in its native portrait) and 106×45 (a 1080p monitor).

## Try it in a terminal first

The dashboard runs in any terminal, no device needed. From this directory:

```sh
mix deps.get
iex -S mix
```

```elixir
iex> RpiFramebuffer.run()
```

In a terminal the 3D object and the photo fall back to what the terminal supports (half blocks, or Kitty/Sixel graphics), and the System tab shows the laptop. Start it from a real terminal: a backgrounded or piped `mix run` has no TTY to draw on.

```sh
mix test
```

runs the whole project on the host, surface included.

## Build the firmware

The Nerves systems are held at 2.0.x, which run OTP 28, and Nerves only builds a release with an Elixir compiled for the target's OTP major. `elixir --version` says which one is in use ("compiled with Erlang/OTP 28"). With [mise](https://mise.jdx.dev), for this directory:

```sh
mise use erlang@28 elixir@1.19.4-otp-28
mix local.hex --force && mix local.rebar --force
mix archive.install hex nerves_bootstrap
```

Then:

```sh
export MIX_TARGET=rpi4
mix deps.get
mix firmware
mix burn              # first time, with the microSD in a reader, then move the card to the Pi
```

The targets are `rpi4`, `rpi5`, `rpi3`, and `rpi0_2`; only `rpi4` has run on hardware. The firmware needs an SSH public key in `~/.ssh` at build time (see `config/target.exs`).

Why 2.0.x: the 2.1.x systems moved to Linux 6.18, where the Touch Display 2 overlay drives the backlight through `pwm-backlight`, and their kernel config does not build that driver (`CONFIG_BACKLIGHT_PWM`). The DSI panel then never finishes probing (`mipi-dsi fe700000.dsi.0: deferred probe pending` in `dmesg`, an empty `/sys/class/backlight`) and `/dev/fb0` never appears. HDMI is not affected, so a project without a DSI panel can move to `~> 2.1`.

Later builds go over the network:

```sh
mix firmware && mix upload nerves.local
```

## Connect

`config/target.exs` sets up three links, and `mdns_lite` answers as `nerves.local` on all of them:

- **USB-C gadget** (`usb0`): one cable from the laptop to the Pi's USB-C port carries power and a point-to-point network. A Pi 4 with a display draws more than some laptop ports give: `Under-voltage detected` in `dmesg` means it needs a wall supply, with Ethernet or WiFi for the network instead.
- **Ethernet** (`eth0`), DHCP.
- **WiFi** (`wlan0`), configured at runtime with `VintageNetWiFi.quick_configure/2`.

```sh
ssh nerves.local
```

opens IEx. The Erlang console is **not** on the display: `ctty: "ttyS0"` moves it to the GPIO serial port so the kernel console and IEx stay off the panel.

## How the surface works

`lib/rpi_framebuffer/surface.ex` is short; the library does the rest.

1. `init/1` opens the framebuffer with `RasterExRatatui.Framebuffer.open/2`, which also reads `virtual_size`, `bits_per_pixel`, and `stride` from `/sys/class/graphics/fb0`. The display drivers are kernel modules that load during boot, so the device can appear seconds after the application starts: the surface keeps trying for `framebuffer_timeout:` (30 seconds by default) before giving up.
2. `Framebuffer.format_for/1` picks the pixel format from the depth: `RGB565` at 16 bits per pixel (what the KMS fbdev emulation gives the Touch Display 2), `XRGB8888` at 32.
3. The font scale defaults to the largest integer that keeps at least 100 columns on the panel's long side: 2 on 720×1280 (12×16 pixel cells), 3 at 1080p (18×24). `scale:` in the config overrides it.
4. `Framebuffer.unbind_console/2` detaches the kernel's framebuffer console, best effort.
5. `push/2` hands the patches to `Framebuffer.write/2`: one positioned write per patch row, never past the end of the device.
6. The keyboard is the first input device that reports letter keys, read through [`input_event`](https://hex.pm/packages/input_event) with `grab: true`. `RasterExRatatui.Input.Evdev` turns its events into `%ExRatatui.Event.Key{}` structs, and the surface returns them as `{:events, keys, state}`. A missing or unplugged keyboard is looked for again every two seconds.

Options go in `config :rpi_framebuffer, RpiFramebuffer.Surface, [...]`: `scale:`, `framebuffer:` (default `"fb0"`), `framebuffer_timeout:` (default `30_000` ms), `console:` (default `"vtcon1"`), `keyboard:` (default `true`), and `spin_ms:` (default `200`), the interval between two turns of the 3D object.

## Check a new panel

When the panel stays black, the device is checked from IEx over SSH, before the app:

```elixir
RasterExRatatui.Framebuffer.info("fb0")
#=> {:ok, %{width: 720, height: 1280, bits_per_pixel: 16, stride: 1440}}

# Paint it red (16 bits per pixel; at 32 use <<0, 0, 255, 255>>)
File.write!("/dev/fb0", :binary.copy(<<0x00, 0xF8>>, 720 * 1280))

InputEvent.enumerate()
RingLogger.next()
```

The surface logs the geometry, format, and scale it chose, and the keyboard it found.

## Troubleshooting

- **`mix firmware` stops with "Elixir was compiled by a different version of the Erlang/OTP compiler".** The Elixir in use was built for another OTP major than the target's. A version manager's plain `elixir 1.x` is often an older-OTP build even when a newer Erlang runs it. Install the `-otp-28` build as shown above; hex, rebar, and `nerves_bootstrap` are per Elixir install and need installing again.
- **The panel stays dark, SSH works, and `RingLogger.next()` shows `{:framebuffer, {:enoent, ...}}`.** No framebuffer appeared within `framebuffer_timeout:`. `File.ls!("/dev")` without an `fb0` and an empty `/sys/class/backlight` mean the kernel never brought the panel up: see "Why 2.0.x" above for the known cause, and check the ribbon and the display's power leads otherwise.
- **Host tests fail with "Failed to load NIF library ... x86_64".** The other side of the next item: the laptop's NIF was deleted for a firmware build. `MIX_ENV=test mix deps.compile ex_ratatui --force` brings it back.
- **`mix firmware` stops in `scrub-otp-release` with "Unexpected executable format ... x86_64".** A host build (`mix test`, `iex -S mix`) downloaded the laptop's ex_ratatui NIF into `deps/ex_ratatui/priv/native/`, next to the Pi's. Delete the `x86_64` (or `aarch64-apple-darwin`) `.so` there and build again. It comes back after the next host build.
- **The 3D object turns slowly.** A pixel region costs time per pixel it covers, and every turn repaints it. Raise `spin_ms:` so it turns less often. The `:telemetry` events `[:raster_ex_ratatui, :frame, :raster]` and `[:raster_ex_ratatui, :frame, :push]` say where the time goes.
- **A cursor or boot text over the dashboard.** The console unbind failed or the framebuffer console is not `vtcon1`: `cat /sys/class/vtconsole/*/name` tells which one is the "frame buffer device", and `console:` takes its name.
- **No keys.** `InputEvent.enumerate/0` should list a device whose `:ev_key` report includes `:key_a`. Wireless keyboards behind a unifying receiver sometimes show up as several devices; the surface takes the first that matches.
- **The panel is portrait and the stand is landscape.** `/dev/fb0` is always the panel's native orientation; rotating it is the raster's job and is not there yet.

## Related

- [Linux Framebuffers](https://hexdocs.pm/raster_ex_ratatui/framebuffer.html) — the guide this project follows.
- [Building a Surface](https://hexdocs.pm/raster_ex_ratatui/surfaces.html) — the contract.
- [`nerves_ex_ratatui_example`](https://github.com/mcass19/nerves_ex_ratatui_example) — the same Pi drawing TUIs on its *console*, over SSH, and over distribution. This project is the part a console cannot do.
