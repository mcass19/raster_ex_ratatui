defmodule RasterExRatatui.Patch do
  @moduledoc """
  A rectangle of packed pixels to write to a panel.

  `RasterExRatatui.Raster.apply/2` answers a cell diff with a list of patches: one per run of changed cells on a row, one per pixel region that is new or changed, and the margins on a full repaint. A panel driver writes each patch at `(x, y)`, **in list order** (a region patch may overlap cells painted by an earlier patch).

  ## Fields

    * `:x`, `:y` — top-left corner, in panel pixels
    * `:width`, `:height` — size, in pixels
    * `:data` — `width * height` pixels, row-major from the top-left, each packed by the raster's `RasterExRatatui.PixelFormat`. There is no stride padding: row `r` starts at byte `r * width * bytes_per_pixel`.
  """

  @type t :: %__MODULE__{
          x: non_neg_integer(),
          y: non_neg_integer(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          data: binary()
        }

  @enforce_keys [:x, :y, :width, :height, :data]
  defstruct [:x, :y, :width, :height, :data]

  @doc """
  Writes `patch` into `frame`, a row-major buffer `frame_width` pixels wide with `bytes_per_pixel` bytes per pixel, and returns the new buffer.

  For consumers that keep a full frame and apply patches to it (a panel that only accepts whole frames, a PNG snapshot), and for tests. The patch must lie inside the frame.

  ## Examples

      iex> frame = :binary.copy(<<0>>, 4 * 3)
      iex> patch = %RasterExRatatui.Patch{x: 1, y: 1, width: 2, height: 2, data: <<1, 2, 3, 4>>}
      iex> RasterExRatatui.Patch.blit(frame, 4, 1, patch)
      <<0, 0, 0, 0, 0, 1, 2, 0, 0, 3, 4, 0>>
  """
  @spec blit(binary(), pos_integer(), pos_integer(), t()) :: binary()
  def blit(frame, frame_width, bytes_per_pixel, %__MODULE__{} = patch) do
    line = frame_width * bytes_per_pixel
    left = patch.x * bytes_per_pixel
    span = patch.width * bytes_per_pixel
    top = patch.y * line

    rows =
      for r <- 0..(patch.height - 1)//1 do
        start = top + r * line

        [
          binary_part(frame, start, left),
          binary_part(patch.data, r * span, span),
          binary_part(frame, start + left + span, line - left - span)
        ]
      end

    bottom = top + patch.height * line

    IO.iodata_to_binary([
      binary_part(frame, 0, top),
      rows,
      binary_part(frame, bottom, byte_size(frame) - bottom)
    ])
  end
end
