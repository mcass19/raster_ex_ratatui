defmodule RasterExRatatui.Grid do
  @moduledoc """
  The current frame of an `ExRatatui.CellSession`, as a cell map plus the list of pixel regions on screen.

  A `CellSession` hands out a `%Snapshot{}` (every cell) or a `%Diff{}` (only the cells that changed since the last one). The grid folds either into a map keyed by `{col, row}` and reports what changed, which is what lets `RasterExRatatui.Raster` rasterise only those cells.

  Regions are never merged: every payload carries the **complete** list of regions on screen (see `ExRatatui.CellSession.Region`), so the payload's list replaces the grid's outright.

  ## Examples

      iex> alias ExRatatui.CellSession.{Cell, Diff}
      iex> alias RasterExRatatui.Grid
      iex> full = %Diff{width: 2, height: 1, ops: [%Cell{col: 0, symbol: "a"}, %Cell{col: 1, symbol: "b"}]}
      iex> {grid, :all, false} = Grid.apply_diff(Grid.new(), full)
      iex> {grid, [{1, 0}], false} = Grid.apply_diff(grid, %Diff{width: 2, height: 1, ops: [%Cell{col: 1, symbol: "c"}]})
      iex> Grid.cell(grid, 1, 0).symbol
      "c"
  """

  alias ExRatatui.CellSession.{Cell, Diff, Region, Snapshot}

  @typedoc "What changed: every cell, or the positions of the cells that did."
  @type changed :: :all | [{non_neg_integer(), non_neg_integer()}]

  @type t :: %__MODULE__{
          width: non_neg_integer(),
          height: non_neg_integer(),
          cells: %{{non_neg_integer(), non_neg_integer()} => Cell.t()},
          regions: [Region.t()]
        }

  defstruct width: 0, height: 0, cells: %{}, regions: []

  @doc """
  An empty grid, 0×0 with no regions.

  ## Examples

      iex> RasterExRatatui.Grid.new()
      %RasterExRatatui.Grid{width: 0, height: 0, cells: %{}, regions: []}
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Folds a snapshot or a diff into the grid; see `put_snapshot/2` and `apply_diff/2`.

  ## Examples

      iex> alias ExRatatui.CellSession.Snapshot
      iex> {_grid, changed, _} = RasterExRatatui.Grid.apply(RasterExRatatui.Grid.new(), %Snapshot{width: 1, height: 1})
      iex> changed
      :all
  """
  @spec apply(t(), Snapshot.t() | Diff.t()) :: {t(), changed(), regions_changed? :: boolean()}
  def apply(grid, %Snapshot{} = snapshot), do: put_snapshot(grid, snapshot)
  def apply(grid, %Diff{} = diff), do: apply_diff(grid, diff)

  @doc """
  Replaces the grid with a snapshot's cells and regions. Everything counts as changed.

  Returns `{grid, :all, regions_changed?}`.

  ## Examples

      iex> alias ExRatatui.CellSession.{Cell, Snapshot}
      iex> snapshot = %Snapshot{width: 1, height: 1, cells: [%Cell{symbol: "x"}]}
      iex> {grid, :all, false} = RasterExRatatui.Grid.put_snapshot(RasterExRatatui.Grid.new(), snapshot)
      iex> RasterExRatatui.Grid.cell(grid, 0, 0).symbol
      "x"
  """
  @spec put_snapshot(t(), Snapshot.t()) :: {t(), :all, boolean()}
  def put_snapshot(%__MODULE__{} = grid, %Snapshot{} = snapshot) do
    new = %__MODULE__{
      width: snapshot.width,
      height: snapshot.height,
      cells: index(snapshot.cells),
      regions: snapshot.regions
    }

    {new, :all, snapshot.regions != grid.regions}
  end

  @doc """
  Merges a diff's cells into the grid and replaces its regions.

  Returns `{grid, changed, regions_changed?}`. `changed` is `:all` for a full payload (every cell present, which a `CellSession` sends first, after a resize, and after a close) or when the diff's dimensions differ from the grid's; the cell map then starts over from the diff alone. Otherwise it lists the `{col, row}` of every op.

  ## Examples

      iex> alias ExRatatui.CellSession.{Cell, Diff, Region}
      iex> alias RasterExRatatui.Grid
      iex> {grid, :all, false} = Grid.apply_diff(Grid.new(), %Diff{width: 1, height: 1, ops: [%Cell{}]})
      iex> region = %Region{width: 1, height: 1, pixel_width: 1, pixel_height: 1, data: <<0, 0, 0>>}
      iex> {_grid, [], true} = Grid.apply_diff(grid, %Diff{width: 1, height: 1, regions: [region]})
  """
  @spec apply_diff(t(), Diff.t()) :: {t(), changed(), boolean()}
  def apply_diff(%__MODULE__{} = grid, %Diff{width: width, height: height, ops: ops} = diff) do
    regions_changed? = diff.regions != grid.regions

    if {width, height} != {grid.width, grid.height} or length(ops) == width * height do
      new = %__MODULE__{width: width, height: height, cells: index(ops), regions: diff.regions}
      {new, :all, regions_changed?}
    else
      cells =
        Enum.reduce(ops, grid.cells, fn %Cell{} = cell, acc ->
          Map.put(acc, {cell.col, cell.row}, cell)
        end)

      changed = Enum.map(ops, &{&1.col, &1.row})
      {%{grid | cells: cells, regions: diff.regions}, changed, regions_changed?}
    end
  end

  @doc """
  The cell at `{col, row}`, or `nil` when no payload has set it.

  ## Examples

      iex> RasterExRatatui.Grid.cell(RasterExRatatui.Grid.new(), 0, 0)
      nil
  """
  @spec cell(t(), non_neg_integer(), non_neg_integer()) :: Cell.t() | nil
  def cell(%__MODULE__{cells: cells}, col, row), do: Map.get(cells, {col, row})

  defp index(cells), do: Map.new(cells, fn %Cell{} = cell -> {{cell.col, cell.row}, cell} end)
end
