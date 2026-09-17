defmodule RpiFramebuffer.Dashboard.MonitorTest do
  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Subscription
  alias ExRatatui.Widgets.Gauge
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Sparkline
  alias RpiFramebuffer.Dashboard.Monitor

  doctest Monitor

  @moduletag :tmp_dir

  @files %{
    "proc/stat" =>
      "cpu  10 0 10 70 10 0 0 0 0 0\ncpu0 5 0 5 35 5 0 0 0 0 0\ncpu1 5 0 5 35 5 0 0 0 0 0\n",
    "proc/loadavg" => "0.52 0.31 0.18 1/142 2203\n",
    "proc/meminfo" => "MemTotal: 4194304 kB\nMemFree: 100 kB\nMemAvailable: 3145728 kB\n",
    "proc/uptime" => "3725.48 14000.12\n",
    "proc/sys/kernel/hostname" => "nerves-1234\n",
    "proc/sys/kernel/osrelease" => "6.18.33-v8\n",
    "sys/class/thermal/thermal_zone0/temp" => "48312\n"
  }

  setup %{tmp_dir: root} do
    Enum.each(@files, &write(root, &1))
    %{root: root, state: Monitor.init(root: root)}
  end

  describe "init/1" do
    test "reads the device once", %{state: state} do
      assert %{name: "nerves-1234", kernel: "6.18.33-v8"} = state.host

      assert %{
               load: ["0.52", "0.31", "0.18"],
               memory: {1_048_576, 4_194_304},
               uptime: 3725,
               temperature: 48.3,
               stat: [{20, 100}, {10, 50}, {10, 50}]
             } = state.reading

      assert %{cores: [], cpu: [], temperature: []} = state
    end

    test "leaves what it cannot read as nil", %{tmp_dir: root} do
      empty = Path.join(root, "empty")
      File.mkdir_p!(empty)

      assert %{host: %{name: "", kernel: ""}, reading: reading} = Monitor.init(root: empty)
      assert %{stat: [], load: nil, memory: nil, uptime: nil, temperature: nil} = reading
    end

    test "defaults to the real filesystem" do
      assert %{root: "/"} = Monitor.init([])
    end
  end

  describe "update/2" do
    test "a sample turns counter deltas into per-core use", %{root: root, state: state} do
      write(
        root,
        {"proc/stat",
         "cpu  70 0 10 110 10 0 0 0 0 0\ncpu0 55 0 5 35 5 0 0 0 0 0\ncpu1 15 0 5 75 5 0 0 0 0 0\n"}
      )

      write(root, {"sys/class/thermal/thermal_zone0/temp", "61000\n"})

      assert {:ok, state} = Monitor.update({:info, :sample}, state)
      assert state.cores == [100, 20]
      assert state.cpu == [60]
      assert state.temperature == [610]
    end

    test "counts a reading without counters as idle and skips an unknown temperature", %{
      state: state
    } do
      reading = %{state.reading | stat: [], temperature: nil}

      assert %{cores: [], cpu: [0], temperature: []} = Monitor.record(state, reading)
    end

    test "ignores everything else, keys included", %{state: state} do
      assert :ignored = Monitor.update({:info, :other}, state)
    end

    test "samples every second, on screen or not", %{state: state} do
      for active? <- [true, false] do
        assert [%Subscription{interval_ms: 1_000, message: {:tab, Monitor, :sample}}] =
                 Monitor.subscriptions(state, active?)
      end

      assert Monitor.hints(state) == []
    end
  end

  describe "render/2" do
    setup %{state: state} do
      reading = %{state.reading | stat: [{70, 200}, {55, 100}, {15, 100}]}
      %{state: Monitor.record(state, reading)}
    end

    test "shows the device, a gauge per core, memory, and temperature", %{state: state} do
      widgets = Monitor.render(state, %Rect{x: 0, y: 3, width: 60, height: 76})
      text = widgets |> paragraphs() |> Enum.join("\n")

      assert text =~ "host     nerves-1234"
      assert text =~ "uptime   01:02:05"
      assert text =~ "load 0.52 0.31 0.18   now 50%"
      assert text =~ "48.3 °C"

      assert text =~ "cpu0   90%"
      assert text =~ "cpu1   10%"
      assert text =~ "1.0 of 4.0 GB used"

      assert [0.9, 0.1, 0.25] =
               for({%Gauge{ratio: ratio, label: ""}, _rect} <- widgets, do: ratio)

      assert [%Sparkline{data: [50], max: 100}, %Sparkline{data: [183], max: 600}] =
               for({%Sparkline{} = sparkline, _rect} <- widgets, do: sparkline)
    end

    test "uses two columns on a landscape grid", %{state: state} do
      portrait = Monitor.render(state, %Rect{width: 60, height: 76})
      landscape = Monitor.render(state, %Rect{width: 106, height: 41})

      assert Enum.all?(portrait, fn {_widget, rect} -> rect.x < 30 or rect.width < 50 end)
      assert Enum.any?(landscape, fn {_widget, rect} -> rect.x == 53 end)
    end

    test "says n/a for what the host does not have", %{tmp_dir: root} do
      empty = Path.join(root, "bare")
      File.mkdir_p!(empty)
      state = %{Monitor.init(root: empty) | reading: %{Monitor.read(empty) | addresses: []}}

      text =
        state |> Monitor.render(%Rect{width: 60, height: 76}) |> paragraphs() |> Enum.join("\n")

      assert text =~ "host     n/a"
      assert text =~ "uptime   n/a"
      assert text =~ "load n/a"
      assert text =~ "no address yet"
    end

    test "draws on a session at both geometries", %{state: state} do
      for {cols, rows} <- [{60, 80}, {106, 45}] do
        session = CellSession.new(cols, rows)

        assert :ok =
                 CellSession.draw(
                   session,
                   Monitor.render(state, %Rect{width: cols, height: rows})
                 )

        CellSession.close(session)
      end
    end
  end

  defp paragraphs(widgets), do: for({%Paragraph{text: text}, _rect} <- widgets, do: text)

  defp write(root, {path, contents}) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
