defmodule RasterExRatatui.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias RasterExRatatui.Telemetry

  doctest Telemetry

  setup do
    test_pid = self()
    id = "telemetry-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      [
        [:raster_ex_ratatui, :frame, :raster, :start],
        [:raster_ex_ratatui, :frame, :raster, :stop],
        [:raster_ex_ratatui, :input, :forward]
      ],
      &__MODULE__.forward/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  def forward(event, measurements, meta, test_pid),
    do: send(test_pid, {event, measurements, meta})

  # Surface tests running concurrently emit the same event names, so every
  # assertion pins a metadata value unique to the test.
  test "span/3 merges the stop metadata over the start metadata" do
    mod = make_ref()
    assert :ok = Telemetry.span([:frame, :raster], %{mod: mod}, fn -> {:ok, %{patches: 2}} end)

    assert_receive {[:raster_ex_ratatui, :frame, :raster, :start], _, %{mod: ^mod} = start}
    refute Map.has_key?(start, :patches)

    assert_receive {[:raster_ex_ratatui, :frame, :raster, :stop], %{duration: _},
                    %{mod: ^mod, patches: 2}}
  end

  test "execute/3 adds system_time unless given" do
    mod = make_ref()
    Telemetry.execute([:input, :forward], %{}, %{mod: mod})
    assert_receive {[:raster_ex_ratatui, :input, :forward], %{system_time: t}, %{mod: ^mod}}
    assert is_integer(t)

    Telemetry.execute([:input, :forward], %{system_time: 7}, %{mod: mod})
    assert_receive {[:raster_ex_ratatui, :input, :forward], %{system_time: 7}, %{mod: ^mod}}
  end

  describe "probe/3" do
    test "reports the surface's raster and push spans over the window" do
      {:ok, surface} = RasterExRatatui.Test.Surface.start_link(test_pid: self())
      assert_receive {:pushed, _initial}

      # Another surface's spans must not count.
      {:ok, other} = RasterExRatatui.Test.Surface.start_link(test_pid: self())
      assert_receive {:pushed, _initial_other}

      task =
        Task.async(fn ->
          import ExUnit.CaptureIO
          {report, output} = with_io(fn -> Telemetry.probe(surface, 0.3) end)
          {report, output}
        end)

      Process.sleep(50)

      for code <- ~w(a b c) do
        RasterExRatatui.Surface.send_event(surface, %ExRatatui.Event.Key{
          code: code,
          kind: "press"
        })

        RasterExRatatui.Surface.send_event(other, %ExRatatui.Event.Key{code: code, kind: "press"})
      end

      {report, output} = Task.await(task, 2_000)

      assert %{raster: %{n: n, median: median, p90: _, max: max}, push: %{n: n}} = report
      assert n in 1..3
      assert is_float(median) and is_float(max) and max >= median
      assert {before, after_probe} = report.mailbox
      assert is_integer(before) and is_integer(after_probe)

      assert output =~ ~r/raster: n=#{n} in 0.3s  median=[\d.]+ms  p90=[\d.]+ms  max=[\d.]+ms/
      assert output =~ ~r/push:   n=#{n} in 0.3s/
      assert output =~ "surface mailbox: "

      GenServer.stop(surface)
      GenServer.stop(other)
    end

    test "reports nothing for a quiet surface, quietly with print: false" do
      {:ok, surface} = RasterExRatatui.Test.Surface.start_link(test_pid: self())
      assert_receive {:pushed, _initial}

      assert %{raster: nil, push: nil, mailbox: {0, 0}} =
               Telemetry.probe(surface, 0.05, print: false)

      import ExUnit.CaptureIO
      assert capture_io(fn -> Telemetry.probe(surface, 0.05) end) =~ "raster: n=0 in 0.05s"

      # Spans from another surface are ignored, and a surface that stops during
      # the probe reads as an empty mailbox afterwards.
      config = {self(), surface, "id"}
      meta = %{pid: self()}

      assert :ok =
               Telemetry.__probe_handler__([:x, :y, :raster, :stop], %{duration: 1}, meta, config)

      refute_receive {"id", _kind, _ms}

      task = Task.async(fn -> Telemetry.probe(surface, 0.2, print: false) end)
      Process.sleep(50)
      GenServer.stop(surface)
      assert %{mailbox: {0, 0}} = Task.await(task, 1_000)

      assert_raise ArgumentError, ~r/no surface/, fn ->
        Telemetry.probe(:no_such_surface, 0.01)
      end
    end
  end

  test "the default logger logs events until detached" do
    assert :ok = Telemetry.attach_default_logger(level: :warning)
    assert {:error, :already_exists} = Telemetry.attach_default_logger()

    log =
      capture_log(fn ->
        Telemetry.execute([:input, :forward], %{}, %{mod: :app})
      end)

    assert log =~ "[raster_ex_ratatui] raster_ex_ratatui.input.forward"
    assert log =~ ":app"

    assert :ok = Telemetry.detach_default_logger()
    assert {:error, :not_found} = Telemetry.detach_default_logger()
  end
end
