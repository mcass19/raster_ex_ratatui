# RasterExRatatui

Render [ExRatatui](https://github.com/mcass19/ex_ratatui) apps on pixel displays that are not terminals, such as e-ink panels and Linux framebuffers. A library published to Hex — not an application. Pure Elixir, no NIF of its own: it consumes the cell diffs and pixel regions an `ExRatatui.CellSession` produces and turns them into packed pixels.

The consumer-facing API guide lives in [usage-rules.md](usage-rules.md) (shipped with the package). This file is the contributor brief.

## Architecture

- **Pure core** (no processes, fully testable on the host):
  - `RasterExRatatui.Font` behaviour + `Font.Default6x8` (the built-in font), `Font.Art` (compile-time ASCII-art parser), `Font.Generated` (braille/eighths/quadrants for any cell size)
  - `RasterExRatatui.Palette` (colour terms → RGB) and `RasterExRatatui.PixelFormat` behaviour with `Mono` (gray8, 1-bit tone rules + Bayer dither), `RGB565`, `XRGB8888`
  - `RasterExRatatui.Grid` (cell map + region list) and `RasterExRatatui.Raster` (grid → `Patch` list, a full frame, or a PNG; `rotate:` keeps `:size` physical and the grid logical, `cell_at/2` maps back)
- **Session** — `RasterExRatatui.Session`: process-less, owns the cell session, the app server (linked to the caller), and the raster; the caller folds its messages with `handle/2`. Everything that runs an app goes through it
- **Surfaces** — `use RasterExRatatui.Surface`: a supervised process holding a `Session` that adds the consumer's callbacks, `min_interval`, the push, telemetry, and `on_app_exit`. `use RasterExRatatui.Framebuffer.Surface` is a complete one for Linux fbdev + evdev, every callback overridable with a public default
- **Device helpers** — `RasterExRatatui.Framebuffer` (Linux fbdev geometry + writes, `:root` injectable), `RasterExRatatui.Input.Devices` (process-less evdev discovery, grab, retry; reached through the `:input` option so the library never depends on `input_event`), and the pure translators `Input.Evdev` (keys) and `Input.Touch` (fingers → `Mouse` on cells)
- **`examples/`** — a headless snapshot script, a rasterisation benchmark, `rpi_framebuffer/` (a Nerves project with its own `mix.exs`, deps, and tests: `Framebuffer.Surface` on `/dev/fb0`, run with `mise exec erlang@28 elixir@1.19.4-otp-28` and `MIX_TARGET=host` for its tests), and `e_ink/` (a README on the name badge fork, which runs its apps with `Session`). None of it is part of the library's build or coverage; `examples/README.md` is the catalogue page and every new example gets a row there

## Build

- `mix compile`. ex_ratatui is a hex dependency with a precompiled NIF; run mix commands with `EX_RATATUI_BUILD` unset (`env -u EX_RATATUI_BUILD mix ...` when a shell exports it for the sibling ex_ratatui checkout), otherwise its NIF builds from source

## Testing

- CI enforces **100% coverage** (`mix test --cover`); test fixtures under `test/support` (`RasterExRatatui.Test.*`) are excluded in `mix.exs`. Tests belong in the same commit as the code they cover
- No TTY and no device in tests: drive a real `ExRatatui.CellSession.new(cols, rows, font_size: {w, h})` headlessly (`draw/2` + `take_cells_diff/1`) and assert on patches and frames; fake the device with `RasterExRatatui.Test.Panel` (sysfs + `dev/fb0` under `:root`) and `RasterExRatatui.Test.Input` (an `InputEvent` stand-in for `:input`)
- Rotation is checked against `RasterExRatatui.Test.Rotation`, a slow obvious whole-frame rotation; a change to the raster's pixel paths keeps those tests and the patches-equal-frame property green at every angle
- Key codes in `ExRatatui.Event.Key` are lowercase strings and `kind` is the string `"press"`, not an atom — self-consistent tests pass with the wrong values, so check against `ex_ratatui/lib/ex_ratatui/event/key.ex`

## Conventions

- Every public function gets `@doc` + `@spec` with runnable `## Examples` (doctests count toward coverage); every public module gets a `@moduledoc`
- Every feature or behaviour change gets a CHANGELOG entry under `[Unreleased]` (Keep a Changelog groups); breaking changes include a Migration note
- Docs voice: "we" or no subject — never address the reader as "you". Guides use one physical line per paragraph; prose is never hard-wrapped at a column
- Commit subjects use `feat:`/`fix:`/`docs:`/`test:`/`refactor:`/`chore:` prefixes. `@version` bumps happen only in dedicated release commits
- Pre-PR gate: `mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer && mix test --cover`
- When the public API shape changes, update `usage-rules.md` too — downstream agents consume it
