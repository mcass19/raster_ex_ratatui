defmodule RasterExRatatui.Input.TouchTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Mouse
  alias RasterExRatatui.Input.Touch
  alias RasterExRatatui.PixelFormat.Mono
  alias RasterExRatatui.Raster

  doctest Touch

  defp touch(opts \\ []) do
    Touch.new(
      Keyword.merge([size: {24, 16}, cell_at: fn {x, y} -> {div(x, 6), div(y, 8)} end], opts)
    )
  end

  defp syn, do: {:ev_syn, :syn_report, 0}

  defp at(x, y), do: [{:ev_abs, :abs_mt_position_x, x}, {:ev_abs, :abs_mt_position_y, y}, syn()]

  defp kinds({_touch, events}), do: Enum.map(events, &{&1.kind, &1.x, &1.y})

  test "requires size and cell_at" do
    assert_raise ArgumentError, ~r/:size/, fn -> Touch.new(cell_at: & &1) end
    assert_raise ArgumentError, ~r/:cell_at/, fn -> Touch.new(size: {1, 1}) end
  end

  test "scales the controller's axes to the panel and clamps" do
    t = touch(axes: %{x: {0, 4095}, y: {100, 200}})

    assert kinds(Touch.translate_all(t, [{:ev_abs, :abs_mt_tracking_id, 1} | at(4095, 200)])) ==
             [{"down", 3, 1}]

    assert kinds(Touch.translate_all(t, [{:ev_abs, :abs_mt_tracking_id, 1} | at(9_999, -5)])) ==
             [{"down", 3, 0}]
  end

  test "takes a degenerate axis range as pixels" do
    t = touch(axes: %{x: {5, 5}, y: {0, 0}})

    assert kinds(Touch.translate_all(t, [{:ev_key, :btn_touch, 1} | at(13, 99)])) == [
             {"down", 2, 1}
           ]
  end

  test "swaps and inverts the axes when the controller does not follow the panel" do
    down = fn t -> kinds(Touch.translate_all(t, [{:ev_key, :btn_touch, 1} | at(2, 9)])) end

    assert down.(touch()) == [{"down", 0, 1}]
    assert down.(touch(invert_x: true)) == [{"down", 3, 1}]
    assert down.(touch(invert_y: true)) == [{"down", 0, 0}]
    # x along the panel's height: axis x = 2 is panel y = 2, axis y = 9 is panel x = 9.
    assert down.(touch(swap_xy: true, axes: %{x: {0, 15}, y: {0, 23}})) == [{"down", 1, 0}]
  end

  test "a finger that stays in its cell emits nothing more, and lifting outside the grid still ends it" do
    outside = fn {x, y} -> if x < 12, do: {div(x, 6), div(y, 8)}, else: :outside end
    t = touch(cell_at: outside)

    {t, [%Mouse{kind: "down", x: 0, y: 0}]} =
      Touch.translate_all(t, [{:ev_abs, :abs_mt_tracking_id, 3} | at(1, 1)])

    {t, []} = Touch.translate_all(t, at(4, 3))
    {t, []} = Touch.translate_all(t, at(20, 3))

    {t, [%Mouse{kind: "up", x: 0, y: 0}]} =
      Touch.translate_all(t, [{:ev_abs, :abs_mt_tracking_id, -1}, syn()])

    # And nothing at all without a contact.
    assert {^t, []} = Touch.translate_all(t, [syn()])
    assert {^t, []} = Touch.translate_all(t, [{:ev_msc, :msc_timestamp, 5}])
  end

  test "a release with no contact on the grid emits nothing" do
    t = touch()
    assert {_t, []} = Touch.translate_all(t, [{:ev_key, :btn_touch, 0}, syn()])
    assert {_t, []} = Touch.translate_all(t, :disconnect)
  end

  test "maps through a rotated raster's cell_at" do
    raster = Raster.new(size: {24, 16}, format: Mono, rotate: 90)
    t = Touch.new(size: {24, 16}, cell_at: &Raster.cell_at(raster, &1))

    # Panel pixel (5, 10) is the app's (10, 18): column 1, row 2 of the turned 2×3 grid.
    assert kinds(Touch.translate_all(t, [{:ev_abs, :abs_mt_tracking_id, 1} | at(5, 10)])) ==
             [{"down", 1, 2}]
  end
end
