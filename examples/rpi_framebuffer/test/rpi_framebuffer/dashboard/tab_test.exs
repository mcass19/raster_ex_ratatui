defmodule RpiFramebuffer.Dashboard.TabTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias RpiFramebuffer.Dashboard.Tab

  doctest Tab

  test "fit/2 gives an empty rect nothing to draw" do
    assert Tab.fit([1, 2, 3], %Rect{width: 0, height: 1}) == []
  end
end
