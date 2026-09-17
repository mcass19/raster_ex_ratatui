defmodule RpiFramebuffer.Dashboard.ShowcaseTest do
  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.CellSession.Region
  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Subscription
  alias ExRatatui.Widgets.Image
  alias ExRatatui.Widgets.Sparkline
  alias ExRatatui.Widgets.Viewport3D
  alias RpiFramebuffer.Dashboard.Showcase

  doctest Showcase

  setup do
    %{state: Showcase.init([])}
  end

  describe "init/1" do
    test "starts turning a cube with the first photo", %{state: state} do
      assert %{shape: :cube, angle: +0.0, paused?: false, photo: 0, spin_ms: 200} = state
      assert [{%Image{state: ref}, "Marat Gilyadzinov"} | _] = state.photos
      assert is_reference(ref)
      assert length(state.photos) == 4
    end

    test "takes the turn interval from the options" do
      assert %{spin_ms: 500} = Showcase.init(spin_ms: 500)
    end
  end

  describe "update/2" do
    test "s cycles the object and p the photo", %{state: state} do
      assert {:ok, %{shape: :orbit}} = Showcase.update({:event, key("s")}, state)

      state = %{state | photo: 3}
      assert {:ok, %{photo: 0}} = Showcase.update({:event, key("p")}, state)
    end

    test "space pauses, which drops the spin timer", %{state: state} do
      assert [%Subscription{id: :showcase_sample}, %Subscription{id: :showcase_spin}] =
               Showcase.subscriptions(state, true)

      assert {:ok, %{paused?: true} = paused} = Showcase.update({:event, key(" ")}, state)
      assert [%Subscription{id: :showcase_sample}] = Showcase.subscriptions(paused, true)
      assert [{"s", _}, {"p", _}, {"space", "resume"}] = Showcase.hints(paused)
      assert [{"s", _}, {"p", _}, {"space", "pause"}] = Showcase.hints(state)
    end

    test "has no timers while another tab is on screen", %{state: state} do
      assert Showcase.subscriptions(state, false) == []
    end

    test "timer messages come back wrapped for the dashboard", %{state: state} do
      assert [%Subscription{message: {:tab, Showcase, :sample}, interval_ms: 1_000}, spin] =
               Showcase.subscriptions(state, true)

      assert %Subscription{message: {:tab, Showcase, :spin}, interval_ms: 200} = spin
    end

    test "a spin turns the object and a sample records the VM", %{state: state} do
      assert {:ok, turned} = Showcase.update({:info, :spin}, state)
      assert turned.angle > state.angle

      assert {:ok, sampled} = Showcase.update({:info, :sample}, state)
      assert [_delta] = sampled.reductions
      assert [_kib] = sampled.memory
    end

    test "ignores releases and anything else", %{state: state} do
      assert :ignored = Showcase.update({:event, %Key{code: "s", kind: "release"}}, state)
      assert :ignored = Showcase.update({:info, :other}, state)
    end
  end

  describe "record/2" do
    test "keeps reduction deltas and a bounded history", %{state: state} do
      state =
        Enum.reduce(1..250, state, fn i, state ->
          sample = %{state.stats | reductions: state.stats.reductions + i, memory: i * 1024}
          Showcase.record(state, sample)
        end)

      assert length(state.reductions) == 240
      assert List.last(state.reductions) == 250
      assert List.last(state.memory) == 250
    end

    test "never records a negative delta", %{state: state} do
      state = Showcase.record(state, %{state.stats | reductions: 0})
      assert state.reductions == [0]
    end
  end

  describe "render/2" do
    test "puts the panes side by side on a landscape grid", %{state: state} do
      widgets = Showcase.render(state, %Rect{x: 0, y: 3, width: 106, height: 41})

      assert {%Viewport3D{}, %Rect{x: 1, y: 4, width: 51, height: 26}} = find(widgets, Viewport3D)
      assert {%Image{}, %Rect{x: 56, y: 4, width: 46, height: 26}} = find(widgets, Image)
    end

    test "stacks the panes on a portrait grid", %{state: state} do
      widgets = Showcase.render(state, %Rect{x: 0, y: 3, width: 60, height: 76})

      assert {%Viewport3D{}, %Rect{x: 1, y: 4, width: 58}} = find(widgets, Viewport3D)
      assert {%Image{}, %Rect{} = image} = find(widgets, Image)
      assert image.y > 30
      assert image.x > 1 and image.x + image.width < 59
    end

    test "sparklines show the newest samples that fit", %{state: state} do
      state = %{state | reductions: Enum.to_list(1..240)}
      widgets = Showcase.render(state, %Rect{x: 0, y: 0, width: 60, height: 76})

      assert {%Sparkline{data: data}, %Rect{width: 47}} = find(widgets, Sparkline)
      assert length(data) == 47
      assert List.last(data) == 240
    end

    test "draws both bitmaps as pixel regions on a pixel session", %{state: state} do
      session = CellSession.new(60, 80, font_size: {12, 16})
      :ok = CellSession.draw(session, Showcase.render(state, %Rect{width: 60, height: 80}))
      diff = CellSession.take_cells_diff(session)

      assert [%Region{pixel_width: 696}, %Region{}] = diff.regions
      CellSession.close(session)
    end
  end

  defp key(code), do: %Key{code: code, kind: "press", modifiers: []}

  defp find(widgets, module),
    do: Enum.find(widgets, fn {widget, _rect} -> is_struct(widget, module) end)
end
