# Examples

A catalog of `raster_ex_ratatui` examples. None of them needs a terminal.

## Catalog

| Example | What to see |
|---------|-------------|
| [`headless/snapshot.exs`](headless/snapshot.exs) | A dashboard with text, a gauge, a sparkline, and a `Viewport3D` cube rasterised twice from the same widgets: a colour frame (`XRGB8888` at scale 2, written as PPM) and a 1-bit e-ink frame (`Mono`, written as PGM). Runs anywhere: `mix run examples/headless/snapshot.exs`. |

## Where to start

Run `headless/snapshot.exs` and open the two images: it is the whole pipeline (app widgets, `CellSession` diff with a pixel region, `Raster.apply/2`, `Raster.frame/1`) in one file, and the same widgets under two pixel formats show what a format decides.

## Related guides

- [Building a Surface](https://hexdocs.pm/raster_ex_ratatui/surfaces.html) — the contract a device implements.
- [Fonts](https://hexdocs.pm/raster_ex_ratatui/fonts.html) and [Pixel Formats](https://hexdocs.pm/raster_ex_ratatui/pixel_formats.html) — making the output fit a panel.
