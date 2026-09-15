# Pixel Formats

A `RasterExRatatui.PixelFormat` is the colour policy of a panel. The raster never builds pixels itself: it asks the format what a cell's foreground and background look like and how to pack a region's RGB pixel, and tiles those bytes.

## Built-in formats

| Format | Bytes | Layout | Typical panel |
| ------ | ----- | ------ | ------------- |
| `RasterExRatatui.PixelFormat.Mono` | 1 | gray8: `0` ink, `255` paper | e-ink, 1-bit OLED |
| `RasterExRatatui.PixelFormat.RGB565` | 2 | little-endian `rrrrrggg gggbbbbb` | SPI LCDs, 16-bit framebuffers |
| `RasterExRatatui.PixelFormat.XRGB8888` | 4 | little-endian: blue, green, red, `255` | 32-bit framebuffers |

Pass the module as `:format` and its options as `:format_opts`:

```elixir
Raster.new(size: {480, 320}, format: RGB565, format_opts: [reset_bg: {16, 16, 24}])
```

## Colour panels and the palette

`RGB565` and `XRGB8888` resolve every colour through a `RasterExRatatui.Palette`, the panel's stand-in for a terminal theme:

- Named colours (`:red`, `:light_blue`, …) and indexed `0..15` come from the theme, xterm's colours by default. `theme: %{red: {255, 85, 85}}` overrides only what it names.
- Indexed `16..255` is xterm's 6×6×6 colour cube and grayscale ramp.
- `{:rgb, r, g, b}` is used as is.
- `:reset` is `:reset_fg` as a foreground (default a light gray) and `:reset_bg` as a background (default black). `:reset_bg` also paints the margins and skipped cells.
- `:bold` brightens a dark named foreground (`:red` → `:light_red`), as most terminals do, unless `bold_bright: false`; a bitmap font has no bold face otherwise. `:reversed` swaps the two sides. Other modifiers do not change colour.

A light theme is just a palette:

```elixir
format_opts: [reset_fg: {40, 40, 40}, reset_bg: {250, 250, 245}, theme: %{white: {40, 40, 40}}]
```

## 1-bit panels

`Mono` collapses every colour to one of three *tones*: ink, paper, or gray. Gray is a pixel checkerboard, aligned to the panel so neighbouring cells continue the pattern.

| Colour | as `fg` | as `bg` |
| ------ | ------- | ------- |
| `:black` | ink | ink |
| `:reset`, other named, indexed | ink on a paper `bg`, paper on an ink `bg` | paper |
| `{:rgb, r, g, b}` | by luma: ink / gray / paper | same |

The rules keep terminal apps legible without a single colour: text is ink on paper, borders drawn over a `bg: :black` fill become paper on ink, `:reversed` always paints a paper glyph on an ink cell (the way to invert a whole screen), and `Canvas` shapes in `:black` are solid. RGB colours are treated as intent: at or below `:ink_max` luma (default 76) is ink, at or above `:paper_min` (default 178) is paper, and the band between is gray, so a half-block 3D render reads as three tones.

Pixel regions go through a Bayer 4×4 ordered dither on luma. The tile repeats across the panel, so the texture is stable between frames and does not crawl under partial refresh the way error diffusion does. Scenes meant for a 1-bit panel look best with a single light and matte materials that land faces clearly in the ink, gray, and paper bands.

## Writing a format

A format implements five callbacks. `c:RasterExRatatui.PixelFormat.init/1` runs once and returns a config the others receive, so per-pixel work never parses options:

```elixir
defmodule MyPanel.Gray4 do
  @moduledoc "4-bit grayscale, one byte per pixel (0..15), for a gray e-ink controller."
  @behaviour RasterExRatatui.PixelFormat

  alias RasterExRatatui.Palette

  @impl true
  def init(opts), do: Palette.new(opts)

  @impl true
  def bytes_per_pixel(_palette), do: 1

  @impl true
  def cell_paints(cell, palette) do
    {{fr, fg, fb}, {br, bg, bb}} = Palette.cell_colors(cell, palette)
    {level(fr, fg, fb), level(br, bg, bb)}
  end

  @impl true
  def rgb_pixel(r, g, b, _x, _y, _palette), do: level(r, g, b)

  @impl true
  def blank(%Palette{reset_bg: {r, g, b}}), do: level(r, g, b)

  defp level(r, g, b), do: <<div(299 * r + 587 * g + 114 * b, 1000) |> div(17)>>
end
```

`c:RasterExRatatui.PixelFormat.cell_paints/2` may return `{:checker, even, odd}` instead of bytes for a side of the cell, to simulate a tone the panel cannot show; the raster resolves it by the parity of each pixel's panel position. `c:RasterExRatatui.PixelFormat.rgb_pixel/6` receives the position for the same reason (ordered dithering) and can ignore it otherwise.

Region pixels are the expensive path, one `rgb_pixel/6` call per panel pixel a region covers, so keep that function small. ex_ratatui caps region bitmaps at 1280 px on the long side and the raster scales them nearest-neighbour onto larger rects, so the cost is bounded by the rect on the panel, not the scene.
