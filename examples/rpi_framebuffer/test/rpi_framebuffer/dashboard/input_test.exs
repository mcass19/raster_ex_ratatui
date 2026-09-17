defmodule RpiFramebuffer.Dashboard.InputTest do
  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.TextInput
  alias RpiFramebuffer.Dashboard.Input

  doctest Input

  setup do
    %{state: Input.init([])}
  end

  describe "init/1" do
    test "starts with an empty field and no keys", %{state: state} do
      assert %{last: nil, count: 0, recent: [], echo: []} = state
      assert ExRatatui.text_input_get_value(state.field) == ""
      assert Input.subscriptions(state, true) == []
      assert [{"enter", _}, {"esc", _}] = Input.hints(state)
    end
  end

  describe "update/2" do
    test "plain and shifted keys type, repeats included", %{state: state} do
      state = press(state, [key("H", ["shift"]), key("i"), key("i", [], "repeat"), key(" ")])

      assert ExRatatui.text_input_get_value(state.field) == "Hii "
      assert state.count == 4
      assert %Key{code: " "} = state.last
    end

    test "editing keys edit", %{state: state} do
      state = press(state, [key("a"), key("b"), key("left"), key("backspace"), key("end")])

      assert ExRatatui.text_input_get_value(state.field) == "b"
    end

    test "chords and function keys are recorded but never typed", %{state: state} do
      state = press(state, [key("a", ["ctrl"]), key("x", ["alt"]), key("f5"), key("up")])

      assert ExRatatui.text_input_get_value(state.field) == ""
      assert Enum.map(state.recent, &Input.chord/1) == ["ctrl+a", "alt+x", "f5", "up"]
    end

    test "enter moves the line to the echo pane, esc clears it", %{state: state} do
      state = press(state, [key("o"), key("k"), key("enter")])
      assert state.echo == ["ok"]
      assert ExRatatui.text_input_get_value(state.field) == ""

      state = press(state, [key("enter")])
      assert state.echo == ["ok"]

      state = press(state, [key("n"), key("o"), key("esc")])
      assert ExRatatui.text_input_get_value(state.field) == ""
      assert state.echo == ["ok"]
    end

    test "keeps a bounded key history", %{state: state} do
      state = press(state, List.duplicate(key("up"), 250))

      assert state.count == 250
      assert length(state.recent) == 200
    end

    test "ignores releases and everything that is not a key", %{state: state} do
      assert :ignored = Input.update({:event, key("a", [], "release")}, state)
      assert :ignored = Input.update({:info, :tick}, state)
    end
  end

  describe "render/2" do
    test "prompts before the first key", %{state: state} do
      widgets = Input.render(state, %Rect{x: 0, y: 3, width: 60, height: 76})

      assert {%TextInput{state: ref}, %Rect{y: 3, height: 3}} = List.first(widgets)
      assert ref == state.field
      assert text(widgets) =~ "press any key"
      assert " Keys (0) " in titles(widgets)
    end

    test "spells out the last key and lists the newest first", %{state: state} do
      state = press(state, [key("h"), key("i"), key("enter"), key("A", ["shift", "ctrl"])])
      all = state |> Input.render(%Rect{x: 0, y: 3, width: 60, height: 76}) |> text()

      assert all =~ "chord      shift+ctrl+A"
      assert all =~ ~s(code       "A")
      assert all =~ "kind       press"
      assert all =~ "modifiers  shift ctrl"
      assert all =~ "press  shift+ctrl+A\npress  enter\npress  i\npress  h"
      assert all =~ "hi"
    end

    test "shows only what fits the pane", %{state: state} do
      state = press(state, List.duplicate(key("up"), 50) ++ [key("down")])
      all = state |> Input.render(%Rect{x: 0, y: 0, width: 60, height: 15}) |> text()

      assert all =~ "press  down"
      assert length(String.split(all, "press  up")) - 1 == 3
    end

    test "draws on a session at both geometries", %{state: state} do
      state = press(state, [key("a"), key("enter"), key("b")])

      for {cols, rows} <- [{60, 80}, {106, 45}] do
        session = CellSession.new(cols, rows)
        area = %Rect{width: cols, height: rows}
        assert :ok = CellSession.draw(session, Input.render(state, area))
        CellSession.close(session)
      end
    end
  end

  defp key(code, modifiers \\ [], kind \\ "press"),
    do: %Key{code: code, kind: kind, modifiers: modifiers}

  defp press(state, keys) do
    Enum.reduce(keys, state, fn key, state ->
      assert {:ok, state} = Input.update({:event, key}, state)
      state
    end)
  end

  defp titles(widgets), do: for({%Block{title: title}, _rect} <- widgets, do: title)

  defp text(widgets) do
    for {%Paragraph{text: lines}, _rect} <- widgets, line <- lines do
      Enum.map_join(line.spans, & &1.content)
    end
    |> Enum.join("\n")
  end
end
