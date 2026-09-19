defmodule RasterExRatatui.PixelFormat.XRGB8888 do
  @moduledoc """
  32-bit XRGB8888, little-endian: bytes are blue, green, red, then an unused byte written as `255`. A common Linux framebuffer depth; `RasterExRatatui.Framebuffer.format_for/1` picks it from the device instead of assuming it.

  Cell colours resolve through a `RasterExRatatui.Palette` (named and indexed colours via its theme, `:reset` via its default foreground and background, `:bold` and `:reversed` applied); region pixels are packed as they come. Margins and skipped cells take the palette's default background.

  ## Options

  Every `RasterExRatatui.Palette.new/1` option: `:theme`, `:reset_fg`, `:reset_bg`, `:bold_bright`.

  ## Examples

      iex> alias ExRatatui.CellSession.Cell
      iex> alias RasterExRatatui.PixelFormat.XRGB8888
      iex> config = XRGB8888.init([])
      iex> XRGB8888.cell_paints(%Cell{fg: {:rgb, 255, 0, 0}, bg: {:rgb, 0, 255, 0}}, config)
      {<<0, 0, 255, 255>>, <<0, 255, 0, 255>>}
  """

  @behaviour RasterExRatatui.PixelFormat

  alias ExRatatui.CellSession.Cell
  alias RasterExRatatui.Palette

  @impl true
  @doc """
  Builds the palette from `opts`.

  ## Examples

      iex> RasterExRatatui.PixelFormat.XRGB8888.init(reset_bg: {1, 2, 3}).reset_bg
      {1, 2, 3}
  """
  @spec init(keyword()) :: Palette.t()
  def init(opts), do: Palette.new(opts)

  @impl true
  @doc """
  4 bytes per pixel.

  ## Examples

      iex> RasterExRatatui.PixelFormat.XRGB8888.bytes_per_pixel(RasterExRatatui.Palette.new())
      4
  """
  @spec bytes_per_pixel(Palette.t()) :: 4
  def bytes_per_pixel(_palette), do: 4

  @impl true
  @doc """
  The cell's foreground and background, resolved through the palette and packed.

  ## Examples

      iex> alias ExRatatui.CellSession.Cell
      iex> RasterExRatatui.PixelFormat.XRGB8888.cell_paints(%Cell{fg: :reset, bg: :reset, modifiers: [:reversed]}, RasterExRatatui.Palette.new(reset_fg: {255, 0, 0}, reset_bg: {0, 255, 0}))
      {<<0, 255, 0, 255>>, <<0, 0, 255, 255>>}
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

      iex> RasterExRatatui.PixelFormat.XRGB8888.rgb_pixel(255, 0, 0, 0, 0, RasterExRatatui.Palette.new())
      <<0, 0, 255, 255>>
  """
  @spec rgb_pixel(0..255, 0..255, 0..255, non_neg_integer(), non_neg_integer(), Palette.t()) ::
          binary()
  def rgb_pixel(r, g, b, _x, _y, _palette), do: pack(r, g, b)

  @impl true
  @doc """
  Packs a row of RGB pixels in one pass; the position is ignored.

  ## Examples

      iex> RasterExRatatui.PixelFormat.XRGB8888.rgb_row(<<255, 0, 0, 0, 0, 255>>, 0, 0, RasterExRatatui.Palette.new())
      <<0, 0, 255, 255, 255, 0, 0, 255>>
  """
  @spec rgb_row(binary(), non_neg_integer(), non_neg_integer(), Palette.t()) :: binary()
  def rgb_row(row, _x, _y, _palette) do
    for <<r, g, b <- row>>, into: <<>>, do: pack(r, g, b)
  end

  @impl true
  @doc """
  The palette's default background.

  ## Examples

      iex> RasterExRatatui.PixelFormat.XRGB8888.blank(RasterExRatatui.Palette.new(reset_bg: {0, 255, 0}))
      <<0, 255, 0, 255>>
  """
  @spec blank(Palette.t()) :: binary()
  def blank(%Palette{reset_bg: {r, g, b}}), do: pack(r, g, b)

  @impl true
  @doc """
  Each 32-bit pixel as RGB8.

  ## Examples

      iex> RasterExRatatui.PixelFormat.XRGB8888.unpack_row(<<0, 128, 255, 255>>, RasterExRatatui.Palette.new())
      <<255, 128, 0>>
  """
  @spec unpack_row(binary(), term()) :: binary()
  def unpack_row(row, _palette), do: for(<<b, g, r, _x <- row>>, into: <<>>, do: <<r, g, b>>)

  defp pack(r, g, b), do: <<b, g, r, 255>>
end
