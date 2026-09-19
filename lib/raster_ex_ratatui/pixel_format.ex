defmodule RasterExRatatui.PixelFormat do
  @moduledoc """
  Behaviour for packing pixels the way a panel expects them.

  `RasterExRatatui.Raster` never builds pixels itself: it asks the format what a cell's foreground and background look like, and what an RGB pixel from a region looks like at a given position, and tiles those bytes. A format is therefore the whole colour policy of a panel, from "RGB565, little-endian" to "1-bit e-ink with tone rules and a dither".

  Built in:

    * `RasterExRatatui.PixelFormat.Mono` — one gray byte per pixel for 1-bit panels (0 ink, 255 paper)
    * `RasterExRatatui.PixelFormat.RGB565` — 16-bit little-endian
    * `RasterExRatatui.PixelFormat.XRGB8888` — 32-bit little-endian, a common Linux framebuffer depth

  ## Callbacks

  `c:init/1` turns the raster's `format_opts:` into a config term, once; every other callback receives that config, so per-pixel work does not re-read keyword lists.

  `c:cell_paints/2` returns a `t:paint/0` for each side of a cell. Most formats return solid pixel bytes. A format that simulates a tone it cannot show (a gray on a 1-bit panel) returns `{:checker, even, odd}`: the pixel at panel position `(x, y)` takes `even` when `x + y` is even, `odd` otherwise, so the pattern stays aligned across cells.

  `c:rgb_pixel/6` packs one region pixel. The position is there for ordered dithering; formats that do not dither ignore it.

  `c:unpack_row/2` is optional and turns packed pixels back into RGB8, so `RasterExRatatui.Raster.to_png/1` can show what the panel shows.

  `c:rgb_row/4` is optional and packs a whole row of region pixels in one call. The raster prefers it when a format exports it, because regions are the expensive path: one function call per pixel is most of their cost. A format that does not define it gets `rgb_row/5`, the per-pixel fallback, which is exactly what the three built-in formats do in one binary comprehension instead.

  ## Examples

      iex> alias RasterExRatatui.PixelFormat.XRGB8888
      iex> config = XRGB8888.init([])
      iex> XRGB8888.bytes_per_pixel(config)
      4
      iex> XRGB8888.rgb_pixel(255, 128, 0, 0, 0, config)
      <<0, 128, 255, 255>>
  """

  alias ExRatatui.CellSession.Cell

  @typedoc "A module implementing this behaviour."
  @type t :: module()

  @typedoc "The config term returned by `c:init/1`."
  @type config :: term()

  @typedoc "Packed bytes for one pixel, or a two-pixel checkerboard."
  @type paint :: binary() | {:checker, even :: binary(), odd :: binary()}

  @doc "Validates `opts` and precomputes whatever the other callbacks need."
  @callback init(opts :: keyword()) :: config()

  @doc "Bytes per packed pixel."
  @callback bytes_per_pixel(config()) :: pos_integer()

  @doc "`{foreground, background}` paints for a cell, after its colours and modifiers."
  @callback cell_paints(Cell.t(), config()) :: {paint(), paint()}

  @doc "One packed pixel for an RGB colour at panel position `(x, y)`."
  @callback rgb_pixel(
              r :: 0..255,
              g :: 0..255,
              b :: 0..255,
              x :: non_neg_integer(),
              y :: non_neg_integer(),
              config()
            ) :: binary()

  @doc """
  Packs a row of region pixels: `row` holds `n` RGB8 pixels (`3 * n` bytes) that land at panel positions `(x, y)` to `(x + n - 1, y)`. Returns `n` packed pixels.

  Optional. Must produce the same bytes as `n` calls to `c:rgb_pixel/6`.
  """
  @callback rgb_row(row :: binary(), x :: non_neg_integer(), y :: non_neg_integer(), config()) ::
              binary()

  @doc "The packed pixel for areas no cell or region covers (margins, skipped cells)."
  @callback blank(config()) :: binary()

  @doc """
  Unpacks a row of packed pixels back to RGB8, 3 bytes per pixel: what the panel shows, as colours.

  Optional. `RasterExRatatui.Raster.to_png/1` needs it; nothing on the drawing path calls it.
  """
  @callback unpack_row(row :: binary(), config()) :: binary()

  @optional_callbacks rgb_row: 4, unpack_row: 2

  @doc """
  Packs a row of region pixels with `format`, through its `c:rgb_row/4` when it has one and pixel by pixel through `c:rgb_pixel/6` otherwise.

  ## Examples

      iex> alias RasterExRatatui.PixelFormat
      iex> PixelFormat.rgb_row(PixelFormat.RGB565, <<255, 0, 0, 0, 0, 255>>, 0, 0, PixelFormat.RGB565.init([]))
      <<0, 248, 31, 0>>
  """
  @spec rgb_row(t(), binary(), non_neg_integer(), non_neg_integer(), config()) :: binary()
  def rgb_row(format, row, x, y, config) do
    if function_exported?(format, :rgb_row, 4) do
      format.rgb_row(row, x, y, config)
    else
      pixels(format, row, x, y, config, [])
    end
  end

  defp pixels(format, <<r, g, b, rest::binary>>, x, y, config, acc),
    do: pixels(format, rest, x + 1, y, config, [format.rgb_pixel(r, g, b, x, y, config) | acc])

  defp pixels(_format, <<>>, _x, _y, _config, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  @doc """
  Resolves a paint to the pixel bytes at panel position `(x, y)`.

  ## Examples

      iex> RasterExRatatui.PixelFormat.resolve(<<7>>, 3, 4)
      <<7>>

      iex> RasterExRatatui.PixelFormat.resolve({:checker, <<0>>, <<255>>}, 1, 1)
      <<0>>

      iex> RasterExRatatui.PixelFormat.resolve({:checker, <<0>>, <<255>>}, 1, 2)
      <<255>>
  """
  @spec resolve(paint(), non_neg_integer(), non_neg_integer()) :: binary()
  def resolve(paint, x, y)
  def resolve(bytes, _x, _y) when is_binary(bytes), do: bytes
  def resolve({:checker, even, _odd}, x, y) when rem(x + y, 2) == 0, do: even
  def resolve({:checker, _even, odd}, _x, _y), do: odd
end
