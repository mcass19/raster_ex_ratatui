defmodule RasterExRatatui.Test.Gray do
  @moduledoc false
  # A one-byte format that leaves `rgb_row/4` to the raster's per-pixel
  # fallback, and folds the pixel's column into the byte so tests can see
  # which position each pixel was packed at.
  @behaviour RasterExRatatui.PixelFormat

  @impl true
  def init(_opts), do: %{}

  @impl true
  def bytes_per_pixel(_config), do: 1

  @impl true
  def cell_paints(_cell, _config), do: {<<0>>, <<255>>}

  @impl true
  def rgb_pixel(r, g, b, x, _y, _config), do: <<rem(div(r + g + b, 3) + x, 256)>>

  @impl true
  def blank(_config), do: <<255>>
end
