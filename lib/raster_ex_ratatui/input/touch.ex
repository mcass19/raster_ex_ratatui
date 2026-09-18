defmodule RasterExRatatui.Input.Touch do
  @moduledoc """
  Turns evdev touch events into the `ExRatatui.Event.Mouse` events an app expects: a tap is a `"down"` and an `"up"` on the cell under the finger, a finger moving into another cell is a `"drag"`.

  Pure and table-free: keep the struct between calls, since it holds the contact in progress. A panel reports its finger in its own axis units and its own orientation; the translator scales the axes to the panel's pixels, applies `swap_xy:` and `invert_x:`/`invert_y:` when the controller does not follow the panel, and asks `cell_at:` (normally `RasterExRatatui.Raster.cell_at/2` of the surface's raster, which knows the rotation) which cell that pixel is. A finger outside the grid, in the margins, produces nothing until it enters a cell.

  Only the first contact counts: multitouch slots other than `0` are ignored, so a second finger never moves the cursor. Both multitouch type B (`abs_mt_slot`, `abs_mt_tracking_id`, `abs_mt_position_x/y`, what the Goodix controller of the Raspberry Pi Touch Display 2 sends) and single-touch panels (`abs_x/y` with `btn_touch`) are understood, and events are emitted on `syn_report`.

  ## Options

  `new/1` takes:

    * `:size` (required) — the physical panel in pixels, `{width, height}`
    * `:cell_at` (required) — `({px, py} -> {col, row} | :outside)`
    * `:axes` — `%{x: {min, max}, y: {min, max}}` as the controller reports them (`RasterExRatatui.Input.Devices.touch_axes/1`); default the pixel ranges, `{0, width - 1}` and `{0, height - 1}`
    * `:swap_xy` — the controller's x runs along the panel's height (default `false`)
    * `:invert_x`, `:invert_y` — an axis runs the other way (default `false`)

  ## Examples

  A 24×16 panel of 6×8 cells; a tap on pixel (13, 9) is cell (2, 1).

      iex> alias RasterExRatatui.Input.Touch
      iex> touch = Touch.new(size: {24, 16}, cell_at: fn {x, y} -> {div(x, 6), div(y, 8)} end)
      iex> tap = [
      ...>   {:ev_abs, :abs_mt_slot, 0}, {:ev_abs, :abs_mt_tracking_id, 7},
      ...>   {:ev_abs, :abs_mt_position_x, 13}, {:ev_abs, :abs_mt_position_y, 9},
      ...>   {:ev_key, :btn_touch, 1}, {:ev_syn, :syn_report, 0},
      ...>   {:ev_abs, :abs_mt_tracking_id, -1}, {:ev_key, :btn_touch, 0}, {:ev_syn, :syn_report, 0}
      ...> ]
      iex> {_touch, events} = Touch.translate_all(touch, tap)
      iex> Enum.map(events, &{&1.kind, &1.x, &1.y})
      [{"down", 2, 1}, {"up", 2, 1}]
  """

  alias ExRatatui.Event.Mouse

  @type axes :: %{x: {integer(), integer()}, y: {integer(), integer()}}

  @type t :: %__MODULE__{
          size: {pos_integer(), pos_integer()},
          cell_at: ({non_neg_integer(), non_neg_integer()} -> {integer(), integer()} | :outside),
          axes: axes(),
          swap_xy: boolean(),
          invert_x: boolean(),
          invert_y: boolean(),
          slot: integer(),
          touching?: boolean(),
          releasing?: boolean(),
          position: {integer() | nil, integer() | nil},
          cell: {integer(), integer()} | nil
        }

  @enforce_keys [:size, :cell_at, :axes]
  defstruct [
    :size,
    :cell_at,
    :axes,
    swap_xy: false,
    invert_x: false,
    invert_y: false,
    slot: 0,
    touching?: false,
    releasing?: false,
    position: {nil, nil},
    cell: nil
  ]

  @doc """
  Builds the translator (see the moduledoc for the options). Raises `ArgumentError` without `:size` or `:cell_at`.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    {width, height} =
      size = Keyword.get(opts, :size) || raise(ArgumentError, "missing required option :size")

    cell_at =
      Keyword.get(opts, :cell_at) || raise(ArgumentError, "missing required option :cell_at")

    axes = Keyword.get(opts, :axes) || %{x: {0, width - 1}, y: {0, height - 1}}

    %__MODULE__{
      size: size,
      cell_at: cell_at,
      axes: axes,
      swap_xy: Keyword.get(opts, :swap_xy, false),
      invert_x: Keyword.get(opts, :invert_x, false),
      invert_y: Keyword.get(opts, :invert_y, false)
    }
  end

  @doc """
  Folds one evdev event, `{type, code, value}`, and returns the mouse events it completes (only a `syn_report` completes any).

  ## Examples

      iex> alias RasterExRatatui.Input.Touch
      iex> touch = Touch.new(size: {24, 16}, cell_at: fn {x, y} -> {div(x, 6), div(y, 8)} end)
      iex> {touch, []} = Touch.translate(touch, {:ev_abs, :abs_x, 20})
      iex> {touch, []} = Touch.translate(touch, {:ev_abs, :abs_y, 3})
      iex> {touch, []} = Touch.translate(touch, {:ev_key, :btn_touch, 1})
      iex> {_touch, [down]} = Touch.translate(touch, {:ev_syn, :syn_report, 0})
      iex> {down.kind, down.button, down.x, down.y}
      {"down", "left", 3, 0}
  """
  @spec translate(t(), {atom(), atom(), integer()}) :: {t(), [Mouse.t()]}
  def translate(%__MODULE__{} = t, {:ev_abs, :abs_mt_slot, slot}), do: {%{t | slot: slot}, []}

  def translate(%__MODULE__{slot: 0} = t, {:ev_abs, :abs_mt_tracking_id, id}) when id < 0,
    do: {%{t | releasing?: true}, []}

  def translate(%__MODULE__{slot: 0} = t, {:ev_abs, :abs_mt_tracking_id, _id}),
    do: {%{t | touching?: true}, []}

  def translate(%__MODULE__{slot: 0} = t, {:ev_abs, :abs_mt_position_x, x}), do: {put_x(t, x), []}
  def translate(%__MODULE__{slot: 0} = t, {:ev_abs, :abs_mt_position_y, y}), do: {put_y(t, y), []}
  def translate(%__MODULE__{} = t, {:ev_abs, :abs_x, x}), do: {put_x(t, x), []}
  def translate(%__MODULE__{} = t, {:ev_abs, :abs_y, y}), do: {put_y(t, y), []}
  def translate(%__MODULE__{} = t, {:ev_key, :btn_touch, 0}), do: {%{t | releasing?: true}, []}
  def translate(%__MODULE__{} = t, {:ev_key, :btn_touch, _down}), do: {%{t | touching?: true}, []}
  def translate(%__MODULE__{} = t, {:ev_syn, :syn_report, _}), do: report(t)
  def translate(%__MODULE__{} = t, _other), do: {t, []}

  @doc """
  Folds a list of events, or the `:disconnect` `input_event` sends when the panel goes away, which ends a contact in progress with an `"up"`.

  ## Examples

  A finger landing on one cell and sliding to the next; the second finger (slot 1) changes nothing.

      iex> alias RasterExRatatui.Input.Touch
      iex> touch = Touch.new(size: {24, 16}, cell_at: fn {x, y} -> {div(x, 6), div(y, 8)} end)
      iex> {touch, [down]} = Touch.translate_all(touch, [{:ev_abs, :abs_mt_tracking_id, 1}, {:ev_abs, :abs_mt_position_x, 2}, {:ev_abs, :abs_mt_position_y, 2}, {:ev_syn, :syn_report, 0}])
      iex> {touch, []} = Touch.translate_all(touch, [{:ev_abs, :abs_mt_position_x, 4}, {:ev_syn, :syn_report, 0}])
      iex> {touch, []} = Touch.translate_all(touch, [{:ev_abs, :abs_mt_slot, 1}, {:ev_abs, :abs_mt_tracking_id, 2}, {:ev_abs, :abs_mt_position_x, 20}, {:ev_abs, :abs_mt_position_y, 12}, {:ev_syn, :syn_report, 0}])
      iex> {touch, [drag]} = Touch.translate_all(touch, [{:ev_abs, :abs_mt_slot, 0}, {:ev_abs, :abs_mt_position_x, 9}, {:ev_syn, :syn_report, 0}])
      iex> {_touch, [up]} = Touch.translate_all(touch, :disconnect)
      iex> [{down.kind, down.x, down.y}, {drag.kind, drag.x, drag.y}, {up.kind, up.x, up.y}]
      [{"down", 0, 0}, {"drag", 1, 0}, {"up", 1, 0}]

  A finger in the margin is ignored until it enters a cell.

      iex> alias RasterExRatatui.Input.Touch
      iex> outside = fn {x, y} -> if x < 12, do: {div(x, 6), div(y, 8)}, else: :outside end
      iex> touch = Touch.new(size: {24, 16}, cell_at: outside)
      iex> {touch, []} = Touch.translate_all(touch, [{:ev_key, :btn_touch, 1}, {:ev_abs, :abs_x, 20}, {:ev_abs, :abs_y, 0}, {:ev_syn, :syn_report, 0}])
      iex> {_touch, [down]} = Touch.translate_all(touch, [{:ev_abs, :abs_x, 7}, {:ev_syn, :syn_report, 0}])
      iex> {down.kind, down.x, down.y}
      {"down", 1, 0}
  """
  @spec translate_all(t(), [{atom(), atom(), integer()}] | :disconnect) :: {t(), [Mouse.t()]}
  def translate_all(%__MODULE__{} = t, :disconnect) do
    {reset(t), if(t.cell, do: [mouse("up", t.cell)], else: [])}
  end

  def translate_all(%__MODULE__{} = t, events) when is_list(events) do
    {t, reversed} =
      Enum.reduce(events, {t, []}, fn event, {t, acc} ->
        {t, emitted} = translate(t, event)
        {t, Enum.reverse(emitted, acc)}
      end)

    {t, Enum.reverse(reversed)}
  end

  defp put_x(%__MODULE__{position: {_x, y}} = t, x), do: %{t | position: {x, y}}
  defp put_y(%__MODULE__{position: {x, _y}} = t, y), do: %{t | position: {x, y}}

  # A syn_report: the contact ended, or it is somewhere.
  defp report(%__MODULE__{releasing?: true} = t) do
    {%{reset(t) | position: t.position}, if(t.cell, do: [mouse("up", t.cell)], else: [])}
  end

  defp report(%__MODULE__{touching?: true, position: {x, y}} = t) when x != nil and y != nil do
    case t.cell_at.(pixel(t, x, y)) do
      :outside -> {t, []}
      cell when cell == t.cell -> {t, []}
      cell when t.cell == nil -> {%{t | cell: cell}, [mouse("down", cell)]}
      cell -> {%{t | cell: cell}, [mouse("drag", cell)]}
    end
  end

  defp report(%__MODULE__{} = t), do: {t, []}

  defp reset(%__MODULE__{} = t),
    do: %{t | touching?: false, releasing?: false, position: {nil, nil}, cell: nil, slot: 0}

  # The controller's axis values as a panel pixel.
  defp pixel(%__MODULE__{size: {width, height}, axes: axes} = t, ax, ay) do
    {ax, ay, x_axis, y_axis} =
      if t.swap_xy, do: {ay, ax, axes.y, axes.x}, else: {ax, ay, axes.x, axes.y}

    px = scale(ax, x_axis, width)
    py = scale(ay, y_axis, height)
    {if(t.invert_x, do: width - 1 - px, else: px), if(t.invert_y, do: height - 1 - py, else: py)}
  end

  defp scale(value, {min, max}, pixels) when max > min do
    value |> Kernel.-(min) |> Kernel.*(pixels - 1) |> div(max - min) |> clamp(pixels)
  end

  defp scale(value, _degenerate, pixels), do: clamp(value, pixels)

  defp clamp(value, pixels), do: value |> max(0) |> min(pixels - 1)

  defp mouse(kind, {col, row}), do: %Mouse{kind: kind, button: "left", x: col, y: row}
end
