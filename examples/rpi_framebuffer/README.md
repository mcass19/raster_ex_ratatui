# rpi_framebuffer

A Nerves project that puts an ExRatatui dashboard on a Raspberry Pi's display through `/dev/fb0`, with a USB keyboard. The first hardware is a Raspberry Pi 4 with the official Touch Display 2 (7", DSI, 720×1280), but nothing in the project describes a panel: size and depth are read from sysfs at boot, so an HDMI monitor or another Pi works with the same firmware.

It is the example for the **surface process**: `RpiFramebuffer.Surface` is a `RasterExRatatui.Surface` under a supervisor. For a device that keeps its own screen process and uses the pure core instead, see [`e_ink`](../e_ink).

> **Status:** runs on a Raspberry Pi 4 with the Touch Display 2 (Nerves system 2.0.1, ex_ratatui 0.14.1). The dashboard comes up in portrait about twenty seconds after power, with no console or cursor over it, the keyboard is found at boot, and `ctrl+q` restarts the dashboard. With the Showcase tab turning its object five times a second, a frame costs about 43 ms to rasterise and 13 ms to write, and the surface keeps up. Tests run on the host against a fake sysfs and a file standing in for `/dev/fb0`.

## What is on the panel

`RpiFramebuffer.Dashboard` is an ordinary `ExRatatui.App` (reducer runtime) with two tabs. It knows nothing about pixels.

| Tab | What to see |
|-----|-------------|
| **Showcase** | What a console cannot show: a lit, turning `Viewport3D` object and a colour photo as pixel regions at the panel's own resolution, next to BEAM sparklines and a gauge made of cells. `s` next object, `p` next photo, `space` pause. |
| **Input** | The keyboard arriving whole: a text input, the last key with its modifiers spelled out, the keys before it, and an echo pane (`enter` sends, `esc` clears). |

## Try it in a terminal first

The dashboard runs in any terminal, no device needed. From this directory:

```sh
mix deps.get
iex -S mix
```

```elixir
iex> RpiFramebuffer.run()
```

In a terminal the 3D object and the photo fall back to what the terminal supports (half blocks, or Kitty/Sixel graphics). Start it from a real terminal: a backgrounded or piped `mix run` has no TTY to draw on.

```sh
mix test
```

runs the whole project on the host, surface included.

## How the surface works

`lib/rpi_framebuffer/surface.ex` is short; the library does the rest.

1. `init/1` opens the framebuffer with `RasterExRatatui.Framebuffer.open/2`, which also reads `virtual_size`, `bits_per_pixel`, and `stride` from `/sys/class/graphics/fb0`. The display drivers are kernel modules that load during boot, so the device can appear seconds after the application starts: the surface keeps trying for `framebuffer_timeout:` (30 seconds by default) before giving up.
2. `Framebuffer.format_for/1` picks the pixel format from the depth: `RGB565` at 16 bits per pixel (what the KMS fbdev emulation gives the Touch Display 2), `XRGB8888` at 32.
3. The font scale defaults to the largest integer that keeps at least 100 columns on the panel's long side: 2 on 720×1280 (12×16 pixel cells), 3 at 1080p (18×24). `scale:` in the config overrides it.
4. `Framebuffer.unbind_console/2` detaches the kernel's framebuffer console, best effort.
5. `push/2` hands the patches to `Framebuffer.write/2`: one positioned write per patch row, never past the end of the device.
6. The keyboard is the first input device that reports letter keys, read through [`input_event`](https://hex.pm/packages/input_event) with `grab: true`. `RasterExRatatui.Input.Evdev` turns its events into `%ExRatatui.Event.Key{}` structs, and the surface returns them as `{:events, keys, state}`. A missing or unplugged keyboard is looked for again every two seconds.

Options go in `config :rpi_framebuffer, RpiFramebuffer.Surface, [...]`: `scale:`, `framebuffer:` (default `"fb0"`), `framebuffer_timeout:` (default `30_000` ms), `console:` (default `"vtcon1"`), `keyboard:` (default `true`), and `spin_ms:` (default `200`), the interval between two turns of the 3D object.

