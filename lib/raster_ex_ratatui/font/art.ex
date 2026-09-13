defmodule RasterExRatatui.Font.Art do
  @moduledoc """
  ASCII art to glyph bitmaps and back, for hand-drawn fonts.

  Glyphs are drawn with `#` for ink and `.` for background, one line per pixel row. `parse/3` turns the art into the bitstring layout `RasterExRatatui.Font` expects; call it from module attributes so the work happens at compile time.

  A glyph may be drawn smaller than the cell and padded with background on the right and at the bottom, which is how text glyphs get their inter-cell and inter-line spacing without drawing it every time.
  """

  @doc """
  Parses `art` into a `{width, height}` glyph bitstring.

  ## Options

    * `:pad` — `{right, bottom}` background columns and rows added around the art (default `{0, 0}`). The art must then be exactly `width - right` columns by `height - bottom` rows.

  Raises `ArgumentError` when the art does not have that shape or uses a character other than `#` and `.`.

  ## Examples

      iex> RasterExRatatui.Font.Art.parse("#.\\n.#\\n", {2, 2})
      <<0b1001::4>>

      iex> RasterExRatatui.Font.Art.parse("#\\n", {2, 2}, pad: {1, 1})
      <<0b1000::4>>
  """
  @spec parse(String.t(), {pos_integer(), pos_integer()}, keyword()) :: bitstring()
  def parse(art, {width, height}, opts \\ []) when is_binary(art) do
    {pad_right, pad_bottom} = Keyword.get(opts, :pad, {0, 0})
    art_width = width - pad_right
    art_height = height - pad_bottom

    rows = art |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

    if length(rows) != art_height do
      raise ArgumentError, "expected #{art_height} rows of art, got #{length(rows)}"
    end

    bits =
      for row <- rows, into: <<>> do
        pixels = String.graphemes(row)

        if length(pixels) != art_width do
          raise ArgumentError,
                "expected #{art_width} columns of art, got #{length(pixels)} in #{inspect(row)}"
        end

        <<for(pixel <- pixels, into: <<>>, do: pixel_bit(pixel))::bitstring, 0::size(pad_right)>>
      end

    <<bits::bitstring, 0::size(width * pad_bottom)>>
  end

  @doc """
  Renders a `{width, height}` glyph bitstring back to ASCII art, one line per row. Handy when debugging a font or a failing glyph assertion.

  ## Examples

      iex> RasterExRatatui.Font.Art.render(<<0b1001::4>>, {2, 2})
      "#.\\n.#\\n"
  """
  @spec render(bitstring(), {pos_integer(), pos_integer()}) :: String.t()
  def render(bits, {width, height}) when bit_size(bits) == width * height do
    for(<<bit::1 <- bits>>, do: if(bit == 1, do: ?#, else: ?.))
    |> Enum.chunk_every(width)
    |> Enum.map_join(&[&1, ?\n])
  end

  defp pixel_bit("#"), do: <<1::1>>
  defp pixel_bit("."), do: <<0::1>>

  defp pixel_bit(other) do
    raise ArgumentError, "expected # or . in glyph art, got #{inspect(other)}"
  end
end
