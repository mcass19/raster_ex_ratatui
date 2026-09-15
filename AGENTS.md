# RasterExRatatui

Render [ExRatatui](https://github.com/mcass19/ex_ratatui) apps on pixel displays that are not terminals, such as e-ink panels and Linux framebuffers. A library published to Hex — not an application. Pure Elixir, no NIF of its own: it consumes the cell diffs and pixel regions an `ExRatatui.CellSession` produces and turns them into packed pixels.

The consumer-facing API guide lives in [usage-rules.md](usage-rules.md) (shipped with the package). This file is the contributor brief.

## Architecture

- **Pure core** (no processes, fully testable on the host):
  - `RasterExRatatui.Font` behaviour + `Font.Default6x8` (the built-in font), `Font.Art` (compile-time ASCII-art parser), `Font.Generated` (braille/eighths/quadrants for any cell size)
  - `RasterExRatatui.Palette` (colour terms → RGB) and `RasterExRatatui.PixelFormat` behaviour with `Mono` (gray8, 1-bit tone rules + Bayer dither), `RGB565`, `XRGB8888`
  - `RasterExRatatui.Grid` (cell map + region list) and `RasterExRatatui.Raster` (grid → `Patch` list or a full frame)
- **Surface** — `use RasterExRatatui.Surface`: a supervised process that owns the ExRatatui server on a `{:cell_session, ...}` transport, folds diffs through `Raster`, and calls the consumer's `push/2`. Input is the consumer's: it hands `ExRatatui.Event` structs to the surface, which forwards them to the server
- **Device helpers** — `RasterExRatatui.Framebuffer` (Linux fbdev geometry + writes, file access injectable) and `RasterExRatatui.Input.Evdev` (pure evdev key → `ExRatatui.Event.Key` translator; the library does not depend on `input_event`)
- **`examples/`** — a headless snapshot script and a rasterisation benchmark (not part of the library's build or coverage)

## Build

- `mix compile`. ex_ratatui is a hex dependency with a precompiled NIF; run mix commands with `EX_RATATUI_BUILD` unset (`env -u EX_RATATUI_BUILD mix ...` when a shell exports it for the sibling ex_ratatui checkout), otherwise its NIF builds from source

## Testing

- CI enforces **100% coverage** (`mix test --cover`); test fixtures under `test/support` (`RasterExRatatui.Test.*`) are excluded in `mix.exs`. Tests belong in the same commit as the code they cover
- No TTY and no device in tests: drive a real `ExRatatui.CellSession.new(cols, rows, font_size: {w, h})` headlessly (`draw/2` + `take_cells_diff/1`) and assert on patches and frames; inject file access for `Framebuffer`
- Key codes in `ExRatatui.Event.Key` are lowercase strings and `kind` is the string `"press"`, not an atom — self-consistent tests pass with the wrong values, so check against `ex_ratatui/lib/ex_ratatui/event/key.ex`

## Conventions

- Every public function gets `@doc` + `@spec` with runnable `## Examples` (doctests count toward coverage); every public module gets a `@moduledoc`
- Every feature or behaviour change gets a CHANGELOG entry under `[Unreleased]` (Keep a Changelog groups); breaking changes include a Migration note
- Docs voice: "we" or no subject — never address the reader as "you". Guides use one physical line per paragraph; prose is never hard-wrapped at a column
- Commit subjects use `feat:`/`fix:`/`docs:`/`test:`/`refactor:`/`chore:` prefixes. `@version` bumps happen only in dedicated release commits
- Pre-PR gate: `mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer && mix test --cover`
- When the public API shape changes, update `usage-rules.md` too — downstream agents consume it
