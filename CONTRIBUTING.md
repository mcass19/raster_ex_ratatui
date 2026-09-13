# Contributing to RasterExRatatui

Thanks for the interest in contributing!

RasterExRatatui is built on [ExRatatui](https://github.com/mcass19/ex_ratatui). Consider contributing to the upstream library too when a feature is missing or something is not working. Contributions are welcome everywhere!

This guide covers the setup.

## Setup

1. Clone the repo:

```sh
git clone https://github.com/mcass19/raster_ex_ratatui.git
cd raster_ex_ratatui
```

2. Prerequisites:

- **Elixir** 1.17+ and **Erlang/OTP** 26+.
- No device: the library is pure Elixir, and every test runs on the host against a headless `ExRatatui.CellSession`.
- While ex_ratatui is a path dependency (`../ex_ratatui`), a **Rust** toolchain and `EX_RATATUI_BUILD=true` are needed so its NIF builds from source.

3. Fetch dependencies:

```sh
mix deps.get
```

## Running Tests

```sh
mix test
mix test --cover        # must report 100.00% Total
```

The suite never touches a terminal or a display. Rasterisation is tested against cell diffs taken from a real `ExRatatui.CellSession` (created with `font_size:`, so `Viewport3D` and `Image` produce pixel regions), and the device helpers (`RasterExRatatui.Framebuffer`) take their file access as an injected module, so they are covered without `/dev/fb0`. Property-based invariants via [`stream_data`](https://hex.pm/packages/stream_data) run as part of the regular `mix test`.

## Branching and Commits

- Branch from `main`
- Keep commits focused and atomic
- Use descriptive commit message prefixes: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`

## Pull Requests

Before submitting a PR, make sure the following pass:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test --cover
```

- Keep PRs focused — one feature or fix per PR
- Add tests for new functionality
- Add `@doc`, `@spec`, and `@moduledoc` for new public functions and modules
- Update documentation (moduledocs, guides, CHANGELOG, README if applicable)
- For breaking changes, include migration notes in the CHANGELOG
- Follow existing code style and patterns
- Ensure CI passes before requesting review
