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

  test "span/3 merges the stop metadata over the start metadata" do
    assert :ok = Telemetry.span([:frame, :raster], %{mod: :app}, fn -> {:ok, %{patches: 2}} end)

    assert_receive {[:raster_ex_ratatui, :frame, :raster, :start], _, %{mod: :app} = start}
    refute Map.has_key?(start, :patches)

    assert_receive {[:raster_ex_ratatui, :frame, :raster, :stop], %{duration: _},
                    %{mod: :app, patches: 2}}
  end

  test "execute/3 adds system_time unless given" do
    Telemetry.execute([:input, :forward], %{}, %{mod: :app})
    assert_receive {[:raster_ex_ratatui, :input, :forward], %{system_time: t}, %{mod: :app}}
    assert is_integer(t)

    Telemetry.execute([:input, :forward], %{system_time: 7}, %{})
    assert_receive {[:raster_ex_ratatui, :input, :forward], %{system_time: 7}, %{}}
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
