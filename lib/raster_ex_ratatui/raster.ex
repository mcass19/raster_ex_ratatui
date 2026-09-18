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

  ## Rotation

  A panel mounted on its side keeps its native scan order: `/dev/fb0` on a portrait display is portrait however the stand holds it. `rotate: 90 | 180 | 270` turns the app's image clockwise on the way to the panel. `:size` stays the **physical** panel; the grid is computed from the **logical** size, which is the physical size with width and height swapped for 90 and 270 (`logical_size/1`); and every patch, `frame/1`, and `margin/1` come out in physical coordinates, so whatever writes the panel does not know the difference.

      rotate: 90 on a 720×1280 panel      logical (x, y) → physical
                                            90:  (W - 1 - y, x)
        logical 1280×720  ─┐               180:  (W - 1 - x, H - 1 - y)
        ┌───────────────┐  │ clockwise     270:  (y, H - 1 - x)
        │ A B C         │  │               W, H: the physical size
        └───────────────┘  ▼
                        ┌─────┐
                        │ A   │  physical 720×1280
                        │ B   │  (the app's top edge is on the right)
                        │ C   │
                        └─────┘

  Glyphs are rotated once as they enter the cache; a run of cells becomes a vertical strip; a pixel region is gathered from its bitmap already rotated, one panel row at a time. Dithering and checkerboards stay anchored to the panel's own pixel grid, which is what a 1-bit panel wants.
  """

  alias ExRatatui.CellSession.{Cell, Diff, Region, Snapshot}
  alias RasterExRatatui.{Font, Grid, Patch, PixelFormat}

  @cache_limit 4096

  @type size :: {pos_integer(), pos_integer()}

  @typedoc "What `apply/2` folds in: a cell diff or a snapshot from an `ExRatatui.CellSession`."
  @type payload :: Snapshot.t() | Diff.t()

  @typedoc "Clockwise rotation of the app's image on the panel, in degrees."
  @type rotation :: 0 | 90 | 180 | 270

  @type t :: %__MODULE__{
          size: size(),
          logical_size: size(),
          rotate: rotation(),
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
    :logical_size,
    :rotate,
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
    :logical_size,
    :rotate,
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

  @rotations [0, 90, 180, 270]

  @doc """
  Builds a raster for a panel.

  ## Options

    * `:size` (required) — the physical panel size in pixels, `{width, height}`
    * `:format` (required) — a `RasterExRatatui.PixelFormat` module
    * `:font` — a `RasterExRatatui.Font` module (default `RasterExRatatui.Font.Default6x8`)
    * `:scale` — integer magnification of the font's cell (default `1`)
    * `:rotate` — `0`, `90`, `180`, or `270`: how far clockwise the app's image is turned on the panel (default `0`, see the moduledoc)
    * `:format_opts` — passed to the format's `c:RasterExRatatui.PixelFormat.init/1` (default `[]`)

  Raises `ArgumentError` when `:size` or `:format` is missing, when `:size` is not a pair of positive integers, when `:scale` is not a positive integer, when `:rotate` is not one of the four angles, or when not even one cell fits on the panel.

  ## Examples

      iex> alias RasterExRatatui.{Raster, PixelFormat}
      iex> raster = Raster.new(size: {1920, 1080}, format: PixelFormat.XRGB8888, scale: 3)
      iex> {Raster.grid_size(raster), Raster.font_size(raster), Raster.margin(raster)}
      {{106, 45}, {18, 24}, {12, 0}}

  A portrait panel on a landscape stand: the grid is that of the turned image.

      iex> alias RasterExRatatui.{Raster, PixelFormat}
      iex> raster = Raster.new(size: {720, 1280}, format: PixelFormat.RGB565, scale: 2, rotate: 90)
      iex> {Raster.size(raster), Raster.logical_size(raster), Raster.grid_size(raster)}
      {{720, 1280}, {1280, 720}, {106, 45}}
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    size = fetch!(opts, :size)
    format = fetch!(opts, :format)
    font = Keyword.get(opts, :font, Font.Default6x8)
    scale = Keyword.get(opts, :scale, 1)
    rotate = Keyword.get(opts, :rotate, 0)

    unless is_integer(scale) and scale >= 1 do
      raise ArgumentError, "expected :scale to be a positive integer, got: #{inspect(scale)}"
    end

    unless rotate in @rotations do
      raise ArgumentError, "expected :rotate to be 0, 90, 180, or 270, got: #{inspect(rotate)}"
    end

    config = format.init(Keyword.get(opts, :format_opts, []))

    %__MODULE__{
      size: size,
      logical_size: size,
      rotate: rotate,
      font: font,
      format: format,
      config: config,
      scale: scale,
      cell_size: font.cell_size(),
      grid_size: size,
      bytes_per_pixel: format.bytes_per_pixel(config),
      blank: format.blank(config)
    }
    |> geometry(size)
  end

  # Everything that follows from the physical size: the logical size, the
  # effective cell, and the grid. Shared by `new/1` and `resize/2`.
  defp geometry(%__MODULE__{font: font, scale: scale, rotate: rotate} = raster, size) do
    unless match?({w, h} when is_integer(w) and w > 0 and is_integer(h) and h > 0, size) do
      raise ArgumentError,
            "expected :size to be {width, height} in pixels, got: #{inspect(size)}"
    end

    {width, height} = size
    {logical_w, logical_h} = logical = if rotate in [90, 270], do: {height, width}, else: size
    {font_w, font_h} = font.cell_size()
    {cell_w, cell_h} = {font_w * scale, font_h * scale}
    grid_size = {div(logical_w, cell_w), div(logical_h, cell_h)}

    if elem(grid_size, 0) == 0 or elem(grid_size, 1) == 0 do
      raise ArgumentError,
            "a #{width}x#{height} panel fits no #{cell_w}x#{cell_h} cell (font #{inspect(font)}, scale #{scale}, rotate #{rotate})"
    end

    %{
      raster
      | size: size,
        logical_size: logical,
        cell_size: {cell_w, cell_h},
        grid_size: grid_size,
        grid: %Grid{}
    }
  end

  @doc """
  The physical panel size in pixels, `{width, height}`: what patches and `frame/1` are laid out for.

  ## Examples

      iex> RasterExRatatui.Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono) |> RasterExRatatui.Raster.size()
      {400, 300}
  """
  @spec size(t()) :: size()
  def size(%__MODULE__{size: size}), do: size

  @doc """
  The size of the app's image in pixels, `{width, height}`: the physical size, with width and height swapped when the raster rotates by 90 or 270.

  ## Examples

      iex> RasterExRatatui.Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono, rotate: 270) |> RasterExRatatui.Raster.logical_size()
      {300, 400}
  """
  @spec logical_size(t()) :: size()
  def logical_size(%__MODULE__{logical_size: size}), do: size

  @doc """
  How far clockwise the app's image is turned on the panel: `0`, `90`, `180`, or `270`.

  ## Examples

      iex> RasterExRatatui.Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono) |> RasterExRatatui.Raster.rotate()
      0
  """
  @spec rotate(t()) :: rotation()
  def rotate(%__MODULE__{rotate: rotate}), do: rotate

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
  The unused strips on the right and at the bottom of the app's image, in pixels, `{right, bottom}`. On a rotated raster they are on the right and at the bottom as the app sees them; on the panel they are wherever the rotation puts them.

  ## Examples

      iex> RasterExRatatui.Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono) |> RasterExRatatui.Raster.margin()
      {4, 4}

      iex> RasterExRatatui.Raster.new(size: {300, 400}, format: RasterExRatatui.PixelFormat.Mono, rotate: 90) |> RasterExRatatui.Raster.margin()
      {4, 4}
  """
  @spec margin(t()) :: {non_neg_integer(), non_neg_integer()}
  def margin(%__MODULE__{
        logical_size: {width, height},
        cell_size: {cell_w, cell_h},
        grid_size: {cols, rows}
      }) do
    {width - cols * cell_w, height - rows * cell_h}
  end

  @doc """
  The cell under a physical pixel, `{col, row}`, or `:outside` for a pixel in the margins or off the panel.

  The inverse of the rotation mapping in the moduledoc: what a touch controller, which reports the panel's own coordinates, needs to find the cell the app sees under a finger.

  ## Examples

  A 12×16 panel with the 6×8 font: two columns and two rows flat, two columns and one row turned.

      iex> alias RasterExRatatui.{Raster, PixelFormat}
      iex> flat = Raster.new(size: {12, 16}, format: PixelFormat.Mono)
      iex> {Raster.cell_at(flat, {7, 9}), Raster.cell_at(flat, {12, 0}), Raster.cell_at(flat, {-1, 0})}
      {{1, 1}, :outside, :outside}

      iex> alias RasterExRatatui.{Raster, PixelFormat}
      iex> at = fn angle, point -> Raster.cell_at(Raster.new(size: {12, 16}, format: PixelFormat.Mono, rotate: angle), point) end
      iex> {at.(90, {5, 10}), at.(180, {7, 9}), at.(270, {5, 10})}
      {{1, 0}, {0, 0}, {0, 0}}

  Turned by 90, the app's 4-pixel right margin is at the bottom of the panel and its bottom margin on the panel's left:

      iex> alias RasterExRatatui.{Raster, PixelFormat}
      iex> turned = Raster.new(size: {12, 16}, format: PixelFormat.Mono, rotate: 90)
      iex> {Raster.cell_at(turned, {4, 11}), Raster.cell_at(turned, {4, 12}), Raster.cell_at(turned, {3, 11})}
      {{1, 0}, :outside, :outside}
  """
  @spec cell_at(t(), {integer(), integer()}) ::
          {non_neg_integer(), non_neg_integer()} | :outside
  def cell_at(%__MODULE__{} = raster, {px, py}) when is_integer(px) and is_integer(py) do
    {width, height} = raster.size

    if px >= 0 and py >= 0 and px < width and py < height do
      {x, y} = logical_point(raster, px, py)
      {cell_w, cell_h} = raster.cell_size
      {cols, rows} = raster.grid_size
      {col, row} = {div(x, cell_w), div(y, cell_h)}

      if col < cols and row < rows, do: {col, row}, else: :outside
    else
      :outside
    end
  end

  # The app's pixel under a panel pixel: the corner mapping run backwards.
  defp logical_point(%__MODULE__{rotate: 0}, px, py), do: {px, py}
  defp logical_point(%__MODULE__{rotate: 90, size: {pw, _ph}}, px, py), do: {py, pw - 1 - px}

  defp logical_point(%__MODULE__{rotate: 180, size: {pw, ph}}, px, py),
    do: {pw - 1 - px, ph - 1 - py}

  defp logical_point(%__MODULE__{rotate: 270, size: {_pw, ph}}, px, py), do: {ph - 1 - py, px}

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
  Rebuilds the geometry for a new physical panel size, keeping font, format, scale, rotation, and the glyph cache, and clears the grid.

  After a resize the `ExRatatui.CellSession` must be resized to the new `grid_size/1`; its next diff is a full payload, so `apply/2` repaints the whole panel.

  ## Examples

      iex> alias RasterExRatatui.Raster
      iex> raster = Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono)
      iex> raster |> Raster.resize({120, 80}) |> Raster.grid_size()
      {20, 10}

      iex> alias RasterExRatatui.Raster
      iex> raster = Raster.new(size: {400, 300}, format: RasterExRatatui.PixelFormat.Mono, rotate: 90)
      iex> raster |> Raster.resize({80, 120}) |> Raster.grid_size()
      {20, 10}
  """
  @spec resize(t(), size()) :: t()
  def resize(%__MODULE__{} = raster, size), do: geometry(raster, size)

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

  defp fetch!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing required option #{inspect(key)}"
    end
  end

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

    # A scanline sweep: the patches covering the current row, kept in x
    # order, each contributing one slice. There are few patches and many
    # rows (a rotated frame has one cell strip per row of the grid, each
    # crossing almost every panel row), so this stays cheap where a map of
    # every slice does not.
    starts = patches |> Enum.with_index() |> Enum.group_by(fn {patch, _order} -> patch.y end)

    {rows, _active} =
      Enum.map_reduce(0..(height - 1), [], fn y, active ->
        active = sweep(active, Map.get(starts, y, []), y)

        slices =
          for {%Patch{} = patch, order} <- active do
            span = patch.width * bpp
            {patch.x * bpp, binary_part(patch.data, (y - patch.y) * span, span), order}
          end

        {compose_row(slices, line, blank_line), active}
      end)

    {raster, IO.iodata_to_binary(rows)}
  end

  # The patches covering row `y`, in x order: the ones still active from
  # the row before, minus those that ended, plus those that start here.
  defp sweep(active, [], y),
    do: Enum.reject(active, fn {patch, _order} -> patch.y + patch.height <= y end)

  defp sweep(active, started, y) do
    Enum.sort_by(sweep(active, [], y) ++ started, fn {patch, order} -> {patch.x, order} end)
  end

  # One frame row, as iodata, from its `{offset, bytes, order}` slices in x
  # order. Every row has at least one: the grid and the margins cover the
  # panel. Slices that do not overlap (the usual case, and every case
  # without regions) are laid end to end with blank gaps, never copying the
  # row. Slices that do overlap (regions over regions) are written over the
  # row in patch order, so the later wins.
  defp compose_row(slices, line, blank_line) do
    if overlapping?(slices) do
      slices
      |> Enum.sort_by(&elem(&1, 2))
      |> Enum.reduce(blank_line, fn {offset, bytes, _order}, acc ->
        tail = offset + byte_size(bytes)

        <<binary_part(acc, 0, offset)::binary, bytes::binary,
          binary_part(acc, tail, line - tail)::binary>>
      end)
    else
      fill_row(slices, 0, line, blank_line)
    end
  end

  defp fill_row([], at, line, blank_line), do: [binary_part(blank_line, at, line - at)]

  defp fill_row([{offset, bytes, _order} | rest], at, line, blank_line) do
    gap = binary_part(blank_line, at, offset - at)
    [gap, bytes | fill_row(rest, offset + byte_size(bytes), line, blank_line)]
  end

  defp overlapping?([{offset, bytes, _}, {next, _, _} = slice | rest]),
    do: offset + byte_size(bytes) > next or overlapping?([slice | rest])

  defp overlapping?(_one_or_none), do: false

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
    {width, height} = raster.logical_size
    {right, bottom} = margin(raster)
    {cols, rows} = raster.grid_size
    {cell_w, cell_h} = raster.cell_size

    [
      {cols * cell_w, 0, right, height},
      {0, rows * cell_h, width - right, bottom}
    ]
    |> Enum.filter(fn {_x, _y, w, h} -> w > 0 and h > 0 end)
    |> Enum.map(fn rect ->
      {x, y, w, h} = physical_rect(raster, rect)
      %Patch{x: x, y: y, width: w, height: h, data: :binary.copy(raster.blank, w * h)}
    end)
  end

  # -- rotation --------------------------------------------------------------

  # A rectangle of the app's image, `{x, y, width, height}`, as the panel
  # sees it. The corner mapping is the moduledoc's: logical (x, y) goes to
  # (W - 1 - y, x) for 90, (W - 1 - x, H - 1 - y) for 180, (y, H - 1 - x)
  # for 270, with W × H the physical size.
  defp physical_rect(%__MODULE__{rotate: 0}, rect), do: rect

  defp physical_rect(%__MODULE__{rotate: 90, size: {pw, _ph}}, {x, y, w, h}),
    do: {pw - y - h, x, h, w}

  defp physical_rect(%__MODULE__{rotate: 180, size: {pw, ph}}, {x, y, w, h}),
    do: {pw - x - w, ph - y - h, w, h}

  defp physical_rect(%__MODULE__{rotate: 270, size: {_pw, ph}}, {x, y, w, h}),
    do: {y, ph - x - w, h, w}

  # A row-major block of `w × h` packed pixels turned by the raster's angle.
  # Used once per glyph block, on its way into the cache.
  defp rotate_pixels(%__MODULE__{rotate: 0}, data, _w, _h), do: data

  defp rotate_pixels(%__MODULE__{rotate: rotate, bytes_per_pixel: bpp}, data, w, h) do
    {out_w, out_h} = if rotate == 180, do: {w, h}, else: {h, w}

    for py <- 0..(out_h - 1), px <- 0..(out_w - 1), into: <<>> do
      {x, y} =
        case rotate do
          90 -> {py, h - 1 - px}
          180 -> {w - 1 - px, h - 1 - py}
          270 -> {w - 1 - py, px}
        end

      binary_part(data, (y * w + x) * bpp, bpp)
    end
  end

  # What to add to a logical pixel's `x + y` to get the parity of the
  # physical pixel it lands on, so checkerboards stay on the panel's grid:
  # rotation adds a constant to x + y (mod 2) per the corner mapping above.
  defp parity_offset(%__MODULE__{rotate: 0}), do: 0
  defp parity_offset(%__MODULE__{rotate: 90, size: {pw, _ph}}), do: pw - 1
  defp parity_offset(%__MODULE__{rotate: 180, size: {pw, ph}}), do: pw + ph
  defp parity_offset(%__MODULE__{rotate: 270, size: {_pw, ph}}), do: ph - 1

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

  # A run of cells on one row. The blocks come out of the cache already
  # rotated: at 0 and 180 the run is one row of blocks (reversed at 180),
  # interleaved row by row; at 90 and 270 it is a vertical strip, the blocks
  # simply stacked (bottom to top at 270).
  defp run_patch(%__MODULE__{} = raster, {row, first, last}) do
    {cell_w, cell_h} = raster.cell_size
    {blocks, raster} = Enum.map_reduce(first..last, raster, &cell_block(&2, &1, row))

    {x, y, width, height} =
      physical_rect(raster, {first * cell_w, row * cell_h, (last - first + 1) * cell_w, cell_h})

    data =
      case raster.rotate do
        0 -> interleave(blocks, cell_w * raster.bytes_per_pixel, cell_h)
        180 -> interleave(Enum.reverse(blocks), cell_w * raster.bytes_per_pixel, cell_h)
        90 -> IO.iodata_to_binary(blocks)
        270 -> IO.iodata_to_binary(Enum.reverse(blocks))
      end

    {%Patch{x: x, y: y, width: width, height: height, data: data}, raster}
  end

  # Blocks side by side: row `dy` of the result is row `dy` of each block.
  defp interleave(blocks, line, rows) do
    for dy <- 0..(rows - 1), block <- blocks, into: <<>> do
      binary_part(block, dy * line, line)
    end
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
      {x, y, width, height} = physical = physical_rect(raster, {x0, y0, rect_w, rect_h})
      rows = region_rows(raster, region, {rect_w, rect_h}, physical)
      %Patch{x: x, y: y, width: width, height: height, data: IO.iodata_to_binary(rows)}
    end
  end

  # One packed row per panel row of the rect, through the format's row path,
  # which receives panel coordinates so dithering stays anchored to the panel.
  defp region_rows(
         %__MODULE__{rotate: 0} = raster,
         %Region{pixel_width: pw, pixel_height: ph} = region,
         {rect_w, rect_h},
         {x0, y0, _rect_w, _rect_h}
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

  # Rotated: each panel row of the patch gathers its samples straight from
  # the bitmap. At 90 and 270 a panel row is a column of the app's image, so
  # the per-row key is a source column and the per-pixel offsets walk source
  # rows; at 180 it is a source row walked backwards. Rows sharing a key (an
  # upscaled region) are gathered once.
  defp region_rows(
         %__MODULE__{rotate: rotate} = raster,
         %Region{pixel_width: pw, pixel_height: ph} = region,
         {rect_w, rect_h},
         {x0, y0, out_w, out_h}
       ) do
    {cell_w, cell_h} = raster.cell_size
    %{format: format, config: config} = raster
    full_w = region.width * cell_w
    full_h = region.height * cell_h
    column = fn dx -> div(dx * pw, full_w) * 3 end
    line = fn dy -> div(dy * ph, full_h) * pw * 3 end

    {offsets, key} =
      case rotate do
        90 -> {for(px <- 0..(out_w - 1), do: line.(rect_h - 1 - px)), column}
        180 -> {for(px <- 0..(out_w - 1), do: column.(rect_w - 1 - px)), &line.(rect_h - 1 - &1)}
        270 -> {for(px <- 0..(out_w - 1), do: line.(px)), &column.(rect_w - 1 - &1)}
      end

    {rows, _last} =
      Enum.map_reduce(0..(out_h - 1), {-1, nil}, fn py, {last_key, last_row} ->
        k = key.(py)
        row = if k == last_key, do: last_row, else: gather(region.data, offsets, k)
        {PixelFormat.rgb_row(format, row, x0, y0 + py, config), {k, row}}
      end)

    rows
  end

  defp gather(data, offsets, base) do
    for offset <- offsets, into: <<>>, do: binary_part(data, offset + base, 3)
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

    parity =
      if is_binary(fg) and is_binary(bg),
        do: 0,
        else: rem(parity_offset(raster) + col * cell_w + row * cell_h, 2)

    codepoint = Font.codepoint(cell.symbol)
    key = {codepoint, fg, bg, parity}

    case raster.cache do
      %{^key => block} ->
        {block, raster}

      cache ->
        block =
          rotate_pixels(
            raster,
            render_block(raster, raster.font.glyph(codepoint), fg, bg, parity),
            cell_w,
            cell_h
          )

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
