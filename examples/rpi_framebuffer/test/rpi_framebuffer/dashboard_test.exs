defmodule RpiFramebuffer.DashboardTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias ExRatatui.Event.Mouse
  alias ExRatatui.Event.Resize
  alias ExRatatui.Frame
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Runtime
  alias ExRatatui.Subscription
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Tabs
  alias RpiFramebuffer.Dashboard
  alias RpiFramebuffer.Dashboard.Input
  alias RpiFramebuffer.Dashboard.Showcase

  doctest Dashboard

  setup do
    {:ok, state} = Dashboard.init([])
    %{state: state}
  end

  describe "init/1" do
    test "opens on the showcase and hands its options to every tab" do
      assert {:ok, %{active: 0, tabs: tabs} = state} = Dashboard.init(spin_ms: 500)

      assert Dashboard.active(state) == Showcase
      assert %{spin_ms: 500} = tabs[Showcase]
      assert %{count: 0} = tabs[Input]
    end
  end

  describe "switching tabs" do
    test "tab and back_tab walk the tabs and wrap", %{state: state} do
      assert {:noreply, %{active: 1} = state} = Dashboard.update({:event, key("tab")}, state)
      assert {:noreply, %{active: 0} = state} = Dashboard.update({:event, key("tab")}, state)

      assert {:noreply, %{active: 1}} =
               Dashboard.update({:event, key("back_tab", ["shift"])}, state)
    end

    test "function keys jump", %{state: state} do
      assert {:noreply, %{active: 1} = state} = Dashboard.update({:event, key("f2")}, state)
      assert Dashboard.active(state) == Input
      assert {:noreply, %{active: 0}} = Dashboard.update({:event, key("f1")}, state)
    end

    test "only the tab on screen animates", %{state: state} do
      assert [:showcase_sample, :showcase_spin] = ids(state)
      assert [] = ids(%{state | active: 1})
    end
  end

  describe "quitting" do
    test "ctrl+q quits anywhere", %{state: state} do
      for active <- 0..1 do
        assert {:stop, _state} =
                 Dashboard.update({:event, key("q", ["ctrl"])}, %{state | active: active})
      end
    end

    test "q quits unless the tab uses it", %{state: state} do
      assert {:stop, _state} = Dashboard.update({:event, key("q")}, state)

      assert {:noreply, typed} = Dashboard.update({:event, key("q")}, %{state | active: 1})
      assert ExRatatui.text_input_get_value(typed.tabs[Input].field) == "q"
    end
  end

  describe "routing" do
    test "keys reach the active tab only", %{state: state} do
      assert {:noreply, state} = Dashboard.update({:event, key("s")}, state)
      assert %{shape: :orbit} = state.tabs[Showcase]
      assert %{count: 0} = state.tabs[Input]
    end

    test "what the active tab ignores does not render", %{state: state} do
      assert {:noreply, ^state, render?: false} = Dashboard.update({:event, key("x")}, state)

      mouse = %Mouse{kind: "down", button: "left", x: 1, y: 1}
      assert {:noreply, ^state, render?: false} = Dashboard.update({:event, mouse}, state)
    end

    test "a resize renders again", %{state: state} do
      assert {:noreply, ^state} =
               Dashboard.update({:event, %Resize{width: 106, height: 45}}, state)
    end

    test "timer messages go back to their tab", %{state: state} do
      assert {:noreply, turned} = Dashboard.update({:info, {:tab, Showcase, :spin}}, state)
      assert turned.tabs[Showcase].angle > state.tabs[Showcase].angle
    end

    test "a tab updating off screen does not render", %{state: state} do
      assert {:noreply, turned, render?: false} =
               Dashboard.update({:info, {:tab, Showcase, :spin}}, %{state | active: 1})

      assert turned.tabs[Showcase].angle > state.tabs[Showcase].angle
    end

    test "ignores unknown tabs and messages", %{state: state} do
      for message <- [
            {:info, {:tab, Showcase, :nope}},
            {:info, {:tab, Nope, :spin}},
            {:info, :nope}
          ] do
        assert {:noreply, ^state, render?: false} = Dashboard.update(message, state)
      end
    end
  end

  describe "render/2" do
    test "frames the active tab between the tab bar and its hints", %{state: state} do
      widgets = Dashboard.render(state, %Frame{width: 60, height: 80})

      assert {%Tabs{titles: ["Showcase", "Input"], selected: 0}, %Rect{y: 0, height: 3}} =
               List.first(widgets)

      assert {%Paragraph{text: line}, %Rect{y: 79, height: 1}} = List.last(widgets)

      assert Enum.map_join(line.spans, & &1.content) =~
               "s shape  p photo  space pause  tab next  ctrl+q quit"

      body = widgets |> Enum.drop(1) |> Enum.drop(-1)
      assert Enum.all?(body, fn {_widget, rect} -> rect.y >= 3 and rect.y + rect.height <= 79 end)
    end

    test "selects the tab on screen", %{state: state} do
      assert [{%Tabs{selected: 1}, _rect} | _] =
               Dashboard.render(%{state | active: 1}, %Frame{width: 106, height: 45})
    end
  end

  describe "as a running app" do
    test "renders, switches tabs, and stops on ctrl+q" do
      {:ok, pid} = Dashboard.start_link(name: nil, test_mode: {60, 40})
      ref = Process.monitor(pid)

      assert %{mode: :reducer, subscription_count: 2} = Runtime.snapshot(pid)

      :ok = Runtime.inject_event(pid, key("tab"))
      assert %{subscription_count: 0} = Runtime.snapshot(pid)

      :ok = Runtime.inject_event(pid, key("q", ["ctrl"]))
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end

  describe "RpiFramebuffer.run/1" do
    test "returns once the dashboard stops" do
      name = :"dashboard_#{System.unique_integer([:positive])}"
      task = Task.async(fn -> RpiFramebuffer.run(name: name, test_mode: {60, 40}) end)

      pid = wait_for(name)
      :ok = Runtime.inject_event(pid, key("q"))

      assert Task.await(task, 1_000) == :ok
    end
  end

  defp key(code, modifiers \\ []), do: %Key{code: code, kind: "press", modifiers: modifiers}

  defp ids(state), do: for(%Subscription{id: id} <- Dashboard.subscriptions(state), do: id)

  defp wait_for(name, attempts \\ 100) do
    case Process.whereis(name) do
      nil when attempts > 0 ->
        Process.sleep(10)
        wait_for(name, attempts - 1)

      pid when is_pid(pid) ->
        pid
    end
  end
end
