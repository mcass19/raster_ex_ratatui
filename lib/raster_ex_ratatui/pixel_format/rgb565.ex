defmodule RasterExRatatui.PixelFormat.RGB565 do
  @moduledoc """
  16-bit RGB565, little-endian: red in the top 5 bits, green in the middle 6, blue in the low 5, low byte first. The usual depth of SPI LCDs and of Linux framebuffers configured with `framebuffer_depth=16`.

  Cell colours resolve through a `RasterExRatatui.Palette` (named and indexed colours via its theme, `:reset` via its default foreground and background, `:bold` and `:reversed` applied); region pixels are packed as they come. Margins and skipped cells take the palette's default background.

  ## Options

  Every `RasterExRatatui.Palette.new/1` option: `:theme`, `:reset_fg`, `:reset_bg`, `:bold_bright`.

  ## Examples

      iex> alias ExRatatui.CellSession.Cell
      iex> alias RasterExRatatui.PixelFormat.RGB565
      iex> config = RGB565.init([])
      iex> RGB565.cell_paints(%Cell{fg: {:rgb, 255, 0, 0}, bg: {:rgb, 0, 255, 0}}, config)
      {<<0, 248>>, <<224, 7>>}
  """

  @behaviour RasterExRatatui.PixelFormat

  import Bitwise

  alias ExRatatui.CellSession.Cell
  alias RasterExRatatui.Palette

  @impl true
  @doc """
  Builds the palette from `opts`.

  ## Examples

      iex> RasterExRatatui.PixelFormat.RGB565.init(reset_bg: {1, 2, 3}).reset_bg
      {1, 2, 3}
  """
  @spec init(keyword()) :: Palette.t()
  def init(opts), do: Palette.new(opts)

  @impl true
  @doc """
  2 bytes per pixel.

  ## Examples

      iex> RasterExRatatui.PixelFormat.RGB565.bytes_per_pixel(RasterExRatatui.Palette.new())
      2
  """
  @spec bytes_per_pixel(Palette.t()) :: 2
  def bytes_per_pixel(_palette), do: 2

  @impl true
  @doc """
  The cell's foreground and background, resolved through the palette and packed.

  ## Examples

      iex> alias ExRatatui.CellSession.Cell
      iex> RasterExRatatui.PixelFormat.RGB565.cell_paints(%Cell{fg: :reset, bg: :reset, modifiers: [:reversed]}, RasterExRatatui.Palette.new(reset_fg: {255, 0, 0}, reset_bg: {0, 255, 0}))
      {<<224, 7>>, <<0, 248>>}
  """
  @spec cell_paints(Cell.t(), Palette.t()) :: {binary(), binary()}
  def cell_paints(%Cell{} = cell, palette) do
    {{fr, fg, fb}, {br, bg, bb}} = Palette.cell_colors(cell, palette)
    {pack(fr, fg, fb), pack(br, bg, bb)}
  end

  @impl true
  @doc """
  Packs an RGB pixel; the position is ignored.

  ## Examples

      iex> RasterExRatatui.PixelFormat.RGB565.rgb_pixel(255, 0, 0, 0, 0, RasterExRatatui.Palette.new())
      <<0, 248>>
  """
  @spec rgb_pixel(0..255, 0..255, 0..255, non_neg_integer(), non_neg_integer(), Palette.t()) ::
          binary()
  def rgb_pixel(r, g, b, _x, _y, _palette), do: pack(r, g, b)

  @impl true
  @doc """
  The palette's default background.

  ## Examples

      iex> RasterExRatatui.PixelFormat.RGB565.blank(RasterExRatatui.Palette.new(reset_bg: {0, 255, 0}))
      <<224, 7>>
  """
  @spec blank(Palette.t()) :: binary()
  def blank(%Palette{reset_bg: {r, g, b}}), do: pack(r, g, b)

  defp pack(r, g, b), do: <<(r >>> 3) <<< 11 ||| (g >>> 2) <<< 5 ||| b >>> 3::little-16>>
end
