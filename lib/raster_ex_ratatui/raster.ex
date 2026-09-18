defmodule RasterExRatatui.Raster do
  @moduledoc """
  Turns `ExRatatui.CellSession` payloads into packed pixels for a panel.

  A raster is a pure value: the panel geometry, a font, a pixel format, an integer scale, and the `RasterExRatatui.Grid` of the current frame. Feed it every snapshot or diff the session produces and it answers with the `RasterExRatatui.Patch` rectangles that changed, packed and ready to write.

      raster = Raster.new(size: {400, 300}, font: Default6x8, format: Mono)
      {cols, rows} = Raster.grid_size(raster)
      session = CellSession.new(cols, rows, font_size: Raster.font_size(raster))

      :ok = CellSession.draw(session, widgets)
      {raster, patches} = Raster.apply(raster, CellSession.take_cells_diff(session))

  ## Geometry

  The effective cell is the font's cell times `scale:`; it is what the session must be created with as `font_size:`, so pixel-mode widgets render bitmaps at the panel's resolution. The grid is the panel size divided by the effective cell, rounded down; the leftover right and bottom strips (`margin/1`) are painted with the format's blank pixel.

  ## Patches

  `apply/2` rasterises only what changed:

    * changed cells, one patch per contiguous run on a row
    * when the region list changed, one patch per region that is new or whose bitmap or rect changed (the bitmap scaled nearest-neighbour onto its cell rect, clipped to the grid), plus the cells a region that went away no longer covers. A region that is the same as in the previous payload costs nothing, so a still image next to an animated one is rasterised once. Overlapping regions stay correct: an unchanged region that touches a repainted area is repainted too, in list order
    * on a full payload (the first diff, a snapshot, a resize), every run of cells on every row, every region, and the margins

  Cells under a pixel region are never rasterised, on full payloads or diffs: they arrive blank and the region paints over them.

  `apply/2` also takes a **list** of payloads and rasterises them as one: the grid is folded through all of them first, so a cell or region that changed several times is drawn once, in its final state. A consumer that falls behind its app (a slow panel, a big pixel region) folds everything queued into one call instead of drawing frames nobody will see; the surface process does exactly that.

  Patches must be written in list order. `frame/1` renders the whole panel as one buffer for panels that only take full frames (`render_frame/1` does the same and keeps the glyph cache it fills); writing `apply/2`'s patches over the previous `frame/1` gives the next one.
  """

  alias ExRatatui.CellSession.{Cell, Diff, Region, Snapshot}
  alias RasterExRatatui.{Font, Grid, Patch, PixelFormat}

  @cache_limit 4096

  @type size :: {pos_integer(), pos_integer()}

  @typedoc "What `apply/2` folds in: a cell diff or a snapshot from an `ExRatatui.CellSession`."
  @type payload :: Snapshot.t() | Diff.t()

  @type t :: %__MODULE__{
          size: size(),
          font: Font.t(),
          format: PixelFormat.t(),
          config: PixelFormat.config(),
          scale: pos_integer(),
          cell_size: size(),
          grid_size: size(),
          bytes_per_pixel: pos_integer(),
          blank: binary(),
          grid: Grid.t(),
          cache: map()
        }

  @enforce_keys [
    :size,
    :font,
    :format,
    :config,
    :scale,
    :cell_size,
    :grid_size,
    :bytes_per_pixel,
    :blank
  ]
  defstruct [
    :size,
    :font,
    :format,
    :config,
    :scale,
    :cell_size,
    :grid_size,
    :bytes_per_pixel,
    :blank,
    grid: %Grid{},
    cache: %{}
  ]

  @doc """
  Builds a raster for a panel.

  ## Options

    * `:size` (required) — panel size in pixels, `{width, height}`
    * `:format` (required) — a `RasterExRatatui.PixelFormat` module
    * `:font` — a `RasterExRatatui.Font` module (default `RasterExRatatui.Font.Default6x8`)
    * `:scale` — integer magnification of the font's cell (default `1`)
    * `:format_opts` — passed to the format's `c:RasterExRatatui.PixelFormat.init/1` (default `[]`)

  Raises `ArgumentError` when `scale` is not a positive integer or when not even one cell fits on the panel.

  ## Examples

      iex> alias RasterExRatatui.{Raster, PixelFormat}
      iex> raster = Raster.new(size: {1920, 1080}, format: PixelFormat.XRGB8888, scale: 3)
      iex> {Raster.grid_size(raster), Raster.font_size(raster), Raster.margin(raster)}
      {{106, 45}, {18, 24}, {12, 0}}
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    {width, height} = size = Keyword.fetch!(opts, :size)
    format = Keyword.fetch!(opts, :format)
    font = Keyword.get(opts, :font, Font.Default6x8)
    scale = Keyword.get(opts, :scale, 1)

    unless is_integer(scale) and scale >= 1 do
      raise ArgumentError, "expected :scale to be a positive integer, got: #{inspect(scale)}"
    end

    {font_w, font_h} = font.cell_size()
    {cell_w, cell_h} = {font_w * scale, font_h * scale}
    grid_size = {div(width, cell_w), div(height, cell_h)}

    if elem(grid_size, 0) == 0 or elem(grid_size, 1) == 0 do
      raise ArgumentError,
            "a #{width}x#{height} panel fits no #{cell_w}x#{cell_h} cell (font #{inspect(font)}, scale #{scale})"
    end

    config = format.init(Keyword.get(opts, :format_opts, []))

    %__MODULE__{
      size: size,
      font: font,
      format: format,
      config: config,
      scale: scale,
      cell_size: {cell_w, cell_h},
      grid_size: grid_size,
      bytes_per_pixel: format.bytes_per_pixel(config),
      blank: format.blank(config)
    }
  end

  @doc """
  Panel size in pixels, `{width, height}`.

  ## Examples

      iex> RasterExRatatui.Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono) |> RasterExRatatui.Raster.size()
      {400, 300}
  """
  @spec size(t()) :: size()
  def size(%__MODULE__{size: size}), do: size

  @doc """
  Grid size in cells, `{cols, rows}`: the size to create the `ExRatatui.CellSession` with.

  ## Examples

      iex> RasterExRatatui.Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono) |> RasterExRatatui.Raster.grid_size()
      {66, 37}
  """
  @spec grid_size(t()) :: size()
  def grid_size(%__MODULE__{grid_size: grid_size}), do: grid_size

  @doc """
  Effective cell size in pixels (the font's cell times the scale): the `font_size:` for `ExRatatui.CellSession.new/3`.

  ## Examples

      iex> RasterExRatatui.Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono, scale: 2) |> RasterExRatatui.Raster.font_size()
      {12, 16}
  """
  @spec font_size(t()) :: size()
  def font_size(%__MODULE__{cell_size: cell_size}), do: cell_size

  @doc """
  The unused strips on the right and at the bottom, in pixels, `{right, bottom}`.

  ## Examples

      iex> RasterExRatatui.Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono) |> RasterExRatatui.Raster.margin()
      {4, 4}
  """
  @spec margin(t()) :: {non_neg_integer(), non_neg_integer()}
  def margin(%__MODULE__{
        size: {width, height},
        cell_size: {cell_w, cell_h},
        grid_size: {cols, rows}
      }) do
    {width - cols * cell_w, height - rows * cell_h}
  end

  @doc """
  Bytes per packed pixel, from the format.

  ## Examples

      iex> RasterExRatatui.Raster.new(size: {64, 64}, format: RasterExRatatui.PixelFormat.RGB565) |> RasterExRatatui.Raster.bytes_per_pixel()
      2
  """
  @spec bytes_per_pixel(t()) :: pos_integer()
  def bytes_per_pixel(%__MODULE__{bytes_per_pixel: bpp}), do: bpp

  @doc """
  The raster's current grid.
  """
  @spec grid(t()) :: Grid.t()
  def grid(%__MODULE__{grid: grid}), do: grid

  @doc """
  Rebuilds the geometry for a new panel size, keeping font, format, and scale, and clears the grid.

  After a resize the `ExRatatui.CellSession` must be resized to the new `grid_size/1`; its next diff is a full payload, so `apply/2` repaints the whole panel.

  ## Examples

      iex> alias RasterExRatatui.Raster
      iex> raster = Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono)
      iex> raster |> Raster.resize({120, 80}) |> Raster.grid_size()
      {20, 10}
  """
  @spec resize(t(), size()) :: t()
  def resize(%__MODULE__{} = raster, size) do
    new(size: size, font: raster.font, format: raster.format, scale: raster.scale)
    |> Map.merge(%{config: raster.config, blank: raster.blank, cache: raster.cache})
  end

  @doc """
  Folds a snapshot or diff, or a list of them in order, into the raster and returns the patches that repaint what changed.

  See the moduledoc for which patches are produced. A list produces the patches of its last state only, never of the states in between; an empty list produces none.

  ## Examples

      iex> alias ExRatatui.CellSession.{Cell, Diff}
      iex> alias RasterExRatatui.{Raster, PixelFormat}
      iex> raster = Raster.new(size: {12, 8}, format: PixelFormat.Mono)
      iex> full = %Diff{width: 2, height: 1, ops: [%Cell{col: 0, symbol: "A"}, %Cell{col: 1}]}
      iex> {raster, [row]} = Raster.apply(raster, full)
      iex> {row.x, row.y, row.width, row.height, byte_size(row.data)}
      {0, 0, 12, 8, 96}
      iex> {_raster, [cell]} = Raster.apply(raster, %Diff{width: 2, height: 1, ops: [%Cell{col: 1, symbol: "B"}]})
      iex> {cell.x, cell.width}
      {6, 6}
      iex> twice = [%Diff{width: 2, height: 1, ops: [%Cell{col: 0, symbol: "C"}]}, %Diff{width: 2, height: 1, ops: [%Cell{col: 0, symbol: "D"}]}]
      iex> {_raster, [once]} = Raster.apply(raster, twice)
      iex> {once.x, once.width}
      {0, 6}
  """
  @spec apply(t(), payload() | [payload()]) :: {t(), [Patch.t()]}
  def apply(%__MODULE__{} = raster, payloads) when is_list(payloads) do
    old_regions = drawable(raster.grid.regions)

    {grid, changed, regions_changed?} =
      Enum.reduce(payloads, {raster.grid, [], false}, fn payload, {grid, changed, regions?} ->
        {grid, more, more_regions?} = Grid.apply(grid, payload)
        {grid, merge_changed(changed, more), regions? or more_regions?}
      end)

    patches(%{raster | grid: grid}, old_regions, changed, regions_changed?)
  end

  def apply(%__MODULE__{} = raster, payload), do: __MODULE__.apply(raster, [payload])

  defp merge_changed(:all, _more), do: :all
  defp merge_changed(_changed, :all), do: :all
  defp merge_changed(changed, more), do: more ++ changed

  defp patches(%__MODULE__{grid: grid} = raster, old_regions, changed, regions_changed?) do
    regions = drawable(grid.regions)

    case changed do
      :all ->
        full_patches(raster, regions)

      changed ->
        {stale, repaint} =
          if regions_changed?, do: changed_regions(old_regions, regions), else: {[], []}

        cells = changed ++ region_cells(raster, stale)
        runs = cells |> Enum.filter(&paintable?(&1, raster, regions)) |> runs()
        {cell_patches, raster} = Enum.map_reduce(runs, raster, &run_patch(&2, &1))
        {raster, cell_patches ++ region_patches(raster, repaint)}
    end
  end

  @doc """
  Renders the whole panel as one row-major buffer of `width * height` packed pixels: cells, then regions, then margins.

  ## Examples

      iex> alias ExRatatui.CellSession.{Cell, Snapshot}
      iex> alias RasterExRatatui.{Raster, PixelFormat}
      iex> raster = Raster.new(size: {8, 9}, format: PixelFormat.Mono)
      iex> {raster, _patches} = Raster.apply(raster, %Snapshot{width: 1, height: 1, cells: [%Cell{symbol: "█"}]})
      iex> frame = Raster.frame(raster)
      iex> {byte_size(frame), :binary.at(frame, 0), :binary.at(frame, 6), :binary.at(frame, 8 * 8)}
      {72, 0, 255, 255}
  """
  @spec frame(t()) :: binary()
  def frame(%__MODULE__{} = raster), do: raster |> render_frame() |> elem(1)

  @doc """
  Like `frame/1`, but also returns the raster with every glyph it rendered added to its cache. Use it when rendering frames repeatedly (a panel that only takes full frames) and keep the returned raster.

  ## Examples

      iex> alias ExRatatui.CellSession.{Cell, Snapshot}
      iex> alias RasterExRatatui.{Raster, PixelFormat}
      iex> raster = Raster.new(size: {12, 8}, format: PixelFormat.Mono)
      iex> {raster, _patches} = Raster.apply(raster, %Snapshot{width: 2, height: 1, cells: [%Cell{symbol: "A"}]})
      iex> {rendered, frame} = Raster.render_frame(%{raster | cache: %{}})
      iex> {frame == Raster.frame(raster), map_size(rendered.cache) > 0}
      {true, true}
  """
  @spec render_frame(t()) :: {t(), binary()}
  def render_frame(%__MODULE__{size: {width, height}, bytes_per_pixel: bpp} = raster) do
    {raster, patches} = full_patches(raster, drawable(raster.grid.regions))
    line = width * bpp
    blank_line = :binary.copy(raster.blank, width)

    spans =
      patches
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn %Patch{} = patch, acc ->
        span = patch.width * bpp

        Enum.reduce(0..(patch.height - 1)//1, acc, fn r, acc ->
          slice = {patch.x * bpp, binary_part(patch.data, r * span, span)}
          Map.update(acc, patch.y + r, [slice], &[slice | &1])
        end)
      end)

    frame =
      for y <- 0..(height - 1), into: <<>> do
        spans
        |> Map.get(y, [])
        |> Enum.reduce(blank_line, fn {offset, bytes}, acc ->
          size = byte_size(bytes)
          tail = offset + size

          <<binary_part(acc, 0, offset)::binary, bytes::binary,
            binary_part(acc, tail, line - tail)::binary>>
        end)
      end

    {raster, frame}
  end

  # -- patches ---------------------------------------------------------------

  defp full_patches(%__MODULE__{grid_size: {cols, rows}} = raster, regions) do
    cells =
      for row <- 0..(rows - 1),
          col <- 0..(cols - 1),
          paintable?({col, row}, raster, regions),
          do: {col, row}

    {cell_patches, raster} = Enum.map_reduce(runs(cells), raster, &run_patch(&2, &1))
    {raster, cell_patches ++ region_patches(raster, regions) ++ margin_patches(raster)}
  end

  defp margin_patches(%__MODULE__{} = raster) do
    {width, height} = raster.size
    {right, bottom} = margin(raster)
    {cols, rows} = raster.grid_size
    {cell_w, cell_h} = raster.cell_size

    [
      {cols * cell_w, 0, right, height},
      {0, rows * cell_h, width - right, bottom}
    ]
    |> Enum.filter(fn {_x, _y, w, h} -> w > 0 and h > 0 end)
    |> Enum.map(fn {x, y, w, h} ->
      %Patch{x: x, y: y, width: w, height: h, data: :binary.copy(raster.blank, w * h)}
    end)
  end

  # Positions of every cell inside the grid that a region covers.
  defp region_cells(%__MODULE__{grid_size: {cols, rows}}, regions) do
    for %Region{} = region <- regions,
        row <- region.y..(region.y + region.height - 1)//1,
        row < rows,
        col <- region.x..(region.x + region.width - 1)//1,
        col < cols,
        do: {col, row}
  end

  defp paintable?({col, row}, %__MODULE__{grid_size: {cols, rows}}, regions) do
    col < cols and row < rows and not Enum.any?(regions, &covers?(&1, col, row))
  end

  # What a new region list costs: `stale` are the old regions that are gone
  # (or changed), whose cells need repainting, and `repaint` the new regions
  # to rasterise, in list order.
  #
  # A region equal to one in the old list is skipped, unless it touches an
  # area that is repainted anyway: regions are painted in list order, so where
  # two overlap, repainting one means repainting the ones around it. When the
  # kept regions changed order among themselves, everything is repainted.
  defp changed_regions(old, new) do
    kept = Enum.filter(new, &(&1 in old))

    if kept == Enum.filter(old, &(&1 in new)) do
      stale = old -- kept
      fresh = new -- kept
      {stale, Enum.filter(new, &(&1 in spread(kept, fresh, stale ++ fresh)))}
    else
      {old, new}
    end
  end

  # Grows `repaint` with every kept region that overlaps a dirty rect, until
  # no kept region does.
  defp spread(kept, repaint, dirty) do
    case Enum.split_with(kept, fn region -> Enum.any?(dirty, &overlap?(&1, region)) end) do
      {[], _clear} -> repaint
      {touched, clear} -> spread(clear, repaint ++ touched, dirty ++ touched)
    end
  end

  defp overlap?(%Region{} = a, %Region{} = b) do
    a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and
      b.y < a.y + a.height
  end

  defp covers?(%Region{x: x, y: y, width: w, height: h}, col, row) do
    col >= x and col < x + w and row >= y and row < y + h
  end

  # Regions that produce pixels. A region without a bitmap covers nothing,
  # so the cells under it keep being painted.
  defp drawable(regions) do
    Enum.filter(regions, fn %Region{} = r ->
      r.format == :rgb8 and r.pixel_width > 0 and r.pixel_height > 0 and r.width > 0 and
        r.height > 0
    end)
  end

  # Groups `{col, row}` positions into `{row, first_col, last_col}` runs.
  defp runs(positions) do
    positions
    |> Enum.uniq()
    |> Enum.sort_by(fn {col, row} -> {row, col} end)
    |> Enum.chunk_while(
      nil,
      fn
        {col, row}, {row, first, last} when col == last + 1 -> {:cont, {row, first, col}}
        {col, row}, nil -> {:cont, {row, col, col}}
        {col, row}, run -> {:cont, run, {row, col, col}}
      end,
      fn
        nil -> {:cont, nil}
        run -> {:cont, run, nil}
      end
    )
  end

  defp run_patch(%__MODULE__{} = raster, {row, first, last}) do
    {cell_w, cell_h} = raster.cell_size
    line = cell_w * raster.bytes_per_pixel
    {blocks, raster} = Enum.map_reduce(first..last, raster, &cell_block(&2, &1, row))

    data =
      for dy <- 0..(cell_h - 1), block <- blocks, into: <<>> do
        binary_part(block, dy * line, line)
      end

    patch = %Patch{
      x: first * cell_w,
      y: row * cell_h,
      width: (last - first + 1) * cell_w,
      height: cell_h,
      data: data
    }

    {patch, raster}
  end

  defp region_patches(%__MODULE__{} = raster, regions) do
    regions |> Enum.map(&region_patch(raster, &1)) |> Enum.reject(&is_nil/1)
  end

  defp region_patch(%__MODULE__{} = raster, %Region{} = region) do
    {cell_w, cell_h} = raster.cell_size
    {cols, rows} = raster.grid_size

    x0 = region.x * cell_w
    y0 = region.y * cell_h
    rect_w = min(region.width * cell_w, cols * cell_w - x0)
    rect_h = min(region.height * cell_h, rows * cell_h - y0)

    if rect_w > 0 and rect_h > 0 do
      rows = region_rows(raster, region, {x0, y0}, {rect_w, rect_h})
      %Patch{x: x0, y: y0, width: rect_w, height: rect_h, data: IO.iodata_to_binary(rows)}
    end
  end

  # One packed row per panel row of the rect, through the format's row path.
  defp region_rows(
         %__MODULE__{} = raster,
         %Region{pixel_width: pw, pixel_height: ph} = region,
         {x0, y0},
         {rect_w, rect_h}
       ) do
    {cell_w, cell_h} = raster.cell_size
    %{format: format, config: config} = raster
    full_w = region.width * cell_w
    full_h = region.height * cell_h

    # Nearest-neighbour column offsets into a source row, or nil when the
    # bitmap's rows already are the rect's rows (the usual case: a session
    # created with the raster's font_size renders regions at panel size).
    gather =
      if pw == full_w and rect_w == full_w,
        do: nil,
        else: for(dx <- 0..(rect_w - 1), do: div(dx * pw, full_w) * 3)

    {rows, _last} =
      Enum.map_reduce(0..(rect_h - 1), {-1, nil}, fn dy, {last_sy, last_row} ->
        sy = div(dy * ph, full_h)
        # An upscaled region repeats source rows; gather each one once.
        row = if sy == last_sy, do: last_row, else: source_row(region.data, sy, pw, gather)
        {PixelFormat.rgb_row(format, row, x0, y0 + dy, config), {sy, row}}
      end)

    rows
  end

  defp source_row(data, sy, pw, nil), do: binary_part(data, sy * pw * 3, pw * 3)

  defp source_row(data, sy, pw, gather) do
    source = binary_part(data, sy * pw * 3, pw * 3)
    for offset <- gather, into: <<>>, do: binary_part(source, offset, 3)
  end

  # -- cells -----------------------------------------------------------------

  # The packed pixels of one cell, row-major, cached by what they depend on.
  defp cell_block(%__MODULE__{} = raster, col, row) do
    cell =
      case Grid.cell(raster.grid, col, row) do
        %Cell{skip: false} = cell -> cell
        _missing_or_skipped -> %Cell{}
      end

    {fg, bg} = raster.format.cell_paints(cell, raster.config)
    {cell_w, cell_h} = raster.cell_size
    parity = if is_binary(fg) and is_binary(bg), do: 0, else: rem(col * cell_w + row * cell_h, 2)
    codepoint = Font.codepoint(cell.symbol)
    key = {codepoint, fg, bg, parity}

    case raster.cache do
      %{^key => block} ->
        {block, raster}

      cache ->
        block = render_block(raster, raster.font.glyph(codepoint), fg, bg, parity)
        cache = if map_size(cache) >= @cache_limit, do: %{}, else: cache
        {block, %{raster | cache: Map.put(cache, key, block)}}
    end
  end

  defp render_block(%__MODULE__{font: font, scale: scale}, glyph, fg, bg, _parity)
       when is_binary(fg) and is_binary(bg) do
    {font_w, _font_h} = font.cell_size()
    fg = :binary.copy(fg, scale)
    bg = :binary.copy(bg, scale)

    for row <- glyph_rows(glyph, font_w), into: <<>> do
      line = for bit <- row, into: <<>>, do: if(bit == 1, do: fg, else: bg)
      :binary.copy(line, scale)
    end
  end

  defp render_block(%__MODULE__{font: font, scale: scale}, glyph, fg, bg, parity) do
    {font_w, _font_h} = font.cell_size()

    for {row, gy} <- Enum.with_index(glyph_rows(glyph, font_w)),
        sy <- 0..(scale - 1),
        {bit, gx} <- Enum.with_index(row),
        sx <- 0..(scale - 1),
        into: <<>> do
      paint = if bit == 1, do: fg, else: bg
      PixelFormat.resolve(paint, gx * scale + sx + parity, gy * scale + sy)
    end
  end

  defp glyph_rows(glyph, font_w) do
    for(<<bit::1 <- glyph>>, do: bit) |> Enum.chunk_every(font_w)
  end
end
