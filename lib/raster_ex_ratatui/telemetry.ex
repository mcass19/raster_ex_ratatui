defmodule RasterExRatatui.Telemetry do
  @moduledoc """
  `:telemetry` integration for `raster_ex_ratatui`.

  Mirrors the shape of `ExRatatui.Telemetry` one layer up: events fire at the boundaries this package controls (surface lifecycle, rasterisation, the consumer's `push/2`, input forwarding) rather than at the runtime layer `ex_ratatui` already instruments. Both trees fire concurrently while a surface runs; attach handlers to whichever is needed.

  ## Events

  All events are prefixed with `:raster_ex_ratatui`.

  ### Span events (`:start` / `:stop` / `:exception`)

  | Event | Description | Metadata |
  | ----- | ----------- | -------- |
  | `[:raster_ex_ratatui, :frame, :raster]` | `RasterExRatatui.Raster.apply/2` (or `frame/1`) on one diff from the app server. | `:surface`, `:mod`; `:stop` adds `:cells`, `:regions`, `:patches` |
  | `[:raster_ex_ratatui, :frame, :push]` | The consumer's `c:RasterExRatatui.Surface.push/2` call. | `:surface`, `:mod`, `:push_mode` |

  `:start` events carry `%{monotonic_time: integer, system_time: integer}` as measurements. `:stop` events add `:duration` (native units). On exception the metadata gains `:kind`, `:reason`, and `:stacktrace`.

  ### Single events

  | Event | Description | Measurements | Metadata |
  | ----- | ----------- | ------------ | -------- |
  | `[:raster_ex_ratatui, :surface, :start]` | The surface built its raster and started the app server. | `%{system_time: integer}` | `:surface`, `:mod`, `:size`, `:grid_size` |
  | `[:raster_ex_ratatui, :surface, :stop]` | The surface is terminating. | `%{system_time: integer}` | `:surface`, `:mod`, `:reason` |
  | `[:raster_ex_ratatui, :input, :forward]` | An event was forwarded to the app server. | `%{system_time: integer}` | `:surface`, `:mod`, `:event` |

  ## Attaching a default logger

      RasterExRatatui.Telemetry.attach_default_logger(level: :info)

  That attaches a handler logging every `:stop` and single event. Detach with `detach_default_logger/0`.
  """

  require Logger

  @doc """
  Wraps `fun` in a `:telemetry` span rooted at `[:raster_ex_ratatui | event]`.

  `fun` returns `{result, stop_meta}`; `result` is returned and `stop_meta` is merged over `meta` for the `:stop` event, which is how counts known only after the work (patches produced, for instance) reach handlers.

  ## Examples

      iex> RasterExRatatui.Telemetry.span([:frame, :raster], %{mod: MyApp}, fn -> {:done, %{patches: 3}} end)
      :done
  """
  @spec span([atom(), ...], map(), (-> {result, map()})) :: result when result: term()
  def span(event, meta, fun) when is_list(event) and is_map(meta) and is_function(fun, 0) do
    :telemetry.span([:raster_ex_ratatui | event], meta, fn ->
      {result, stop_meta} = fun.()
      {result, Map.merge(meta, stop_meta)}
    end)
  end

  @doc """
  Emits a single `:telemetry` event rooted at `[:raster_ex_ratatui | event]`.

  `:system_time` is added to the measurements when not already present.

  ## Examples

      iex> RasterExRatatui.Telemetry.execute([:input, :forward], %{}, %{mod: MyApp})
      :ok
  """
  @spec execute([atom(), ...], map(), map()) :: :ok
  def execute(event, measurements, meta)
      when is_list(event) and is_map(measurements) and is_map(meta) do
    measurements = Map.put_new_lazy(measurements, :system_time, &System.system_time/0)
    :telemetry.execute([:raster_ex_ratatui | event], measurements, meta)
  end

  @doc """
  Attaches a logger that prints every `raster_ex_ratatui` telemetry event. Useful during development; detach with `detach_default_logger/0`.

  ## Options

    * `:level` — log level (default: `:debug`).
    * `:events` — list of full event names to attach (default: every `:stop`, `:exception`, and single event).
  """
  @spec attach_default_logger(keyword()) :: :ok | {:error, :already_exists}
  def attach_default_logger(opts \\ []) do
    level = Keyword.get(opts, :level, :debug)
    events = Keyword.get(opts, :events, default_logger_events())

    :telemetry.attach_many(
      handler_id(),
      events,
      &__MODULE__.__default_logger_handler__/4,
      %{level: level}
    )
  end

  @doc """
  Detaches the logger attached with `attach_default_logger/1`.
  """
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger do
    :telemetry.detach(handler_id())
  end

  @doc false
  def __default_logger_handler__(event, measurements, metadata, %{level: level}) do
    Logger.log(level, fn ->
      [
        "[raster_ex_ratatui] ",
        Enum.map_join(event, ".", &to_string/1),
        " ",
        inspect(Map.merge(measurements, metadata), limit: 50, printable_limit: 200)
      ]
    end)
  end

  defp handler_id, do: "raster-ex-ratatui-default-logger"

  defp default_logger_events do
    [
      [:raster_ex_ratatui, :surface, :start],
      [:raster_ex_ratatui, :surface, :stop],
      [:raster_ex_ratatui, :frame, :raster, :stop],
      [:raster_ex_ratatui, :frame, :raster, :exception],
      [:raster_ex_ratatui, :frame, :push, :stop],
      [:raster_ex_ratatui, :frame, :push, :exception],
      [:raster_ex_ratatui, :input, :forward]
    ]
  end
end
