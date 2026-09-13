# Telemetry

`raster_ex_ratatui` emits [`:telemetry`](https://hexdocs.pm/telemetry/) events at the boundaries a surface controls. They sit one layer above the events `ex_ratatui` emits for the app and its runtime; together they show where a frame's time goes, from `render/2` to the panel.

## Event tree at a glance

```
[:raster_ex_ratatui, :surface, :start]   single  — raster built, app server started
[:raster_ex_ratatui, :surface, :stop]    single  — surface terminating
[:raster_ex_ratatui, :frame, :raster]    span    — Raster.apply/2 on one diff
[:raster_ex_ratatui, :frame, :push]      span    — the consumer's push/2
[:raster_ex_ratatui, :input, :forward]   single  — an event forwarded to the app
```

Span events emit `:start` / `:stop` / `:exception` suffixes. The `:frame, :raster` stop event carries `:cells`, `:regions`, and `:patches` counts in its metadata. See `RasterExRatatui.Telemetry` for the full metadata reference.

## Quick start: log every event

```elixir
RasterExRatatui.Telemetry.attach_default_logger(level: :info)
```

Detach with `RasterExRatatui.Telemetry.detach_default_logger/0`.

## Wiring `Telemetry.Metrics`

```elixir
defmodule MyDevice.Telemetry do
  import Telemetry.Metrics

  def metrics do
    [
      # Rasterisation cost per diff; spikes mean big regions or full repaints.
      summary("raster_ex_ratatui.frame.raster.stop.duration", unit: {:native, :millisecond}),

      # How much of the panel each diff touches.
      summary("raster_ex_ratatui.frame.raster.stop.patches"),

      # The device write, usually the slowest step on SPI panels.
      summary("raster_ex_ratatui.frame.push.stop.duration", unit: {:native, :millisecond}),

      counter("raster_ex_ratatui.input.forward"),
      counter("raster_ex_ratatui.surface.start")
    ]
  end
end
```

## Pairing with `ex_ratatui`'s events

| Concern | Owned by |
| ------- | -------- |
| `mount/1`, `handle_event/2`, `render/2`, the cell diff | `[:ex_ratatui, ...]` |
| Rasterising the diff, writing the panel, forwarding device input | `[:raster_ex_ratatui, ...]` |

`[:ex_ratatui, :render, :frame, :stop]` plus `[:raster_ex_ratatui, :frame, :raster, :stop]` plus `[:raster_ex_ratatui, :frame, :push, :stop]` is the complete path of one frame.

## Custom handlers

Attach a captured module function, not an anonymous one (`:telemetry` logs a performance warning otherwise):

```elixir
:telemetry.attach(
  "my-device-push-tracker",
  [:raster_ex_ratatui, :frame, :push, :stop],
  &MyDevice.PushTracker.handle_event/4,
  nil
)
```
