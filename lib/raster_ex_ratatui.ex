defmodule RasterExRatatui do
  @moduledoc """
  Render [ExRatatui](https://hexdocs.pm/ex_ratatui) apps on pixel displays such as e-ink panels, with helpers for Linux framebuffers.

  A terminal turns cells into pixels by itself. A bare panel does not, so something has to paint every cell's glyph in its colours, and blit the bitmaps that pixel-mode widgets (`ExRatatui.Widgets.Viewport3D`, `ExRatatui.Widgets.Image`) hand to an `ExRatatui.CellSession` created with a `:font_size`. This package is that something, in three layers:

      ┌──────────────────────────────────────────────────────────────┐
      │ Surface      use RasterExRatatui.Surface                     │
      │              a process that owns a Session and calls push/2  │
      ├──────────────────────────────────────────────────────────────┤
      │ Session      app server + cell session + raster, no process  │
      │              handle/2 folds renders into patches             │
      ├──────────────────────────────────────────────────────────────┤
      │ Raster       Grid (cells + regions) → [Patch] | full frame   │
      │              Font × Palette × PixelFormat × scale            │
      ├──────────────────────────────────────────────────────────────┤
      │ Device       Framebuffer (fbdev) · Input.Evdev (keyboards)   │
      │              or the consumer's own driver (SPI, e-ink, …)    │
      └──────────────────────────────────────────────────────────────┘

  ## Where to start

    * `RasterExRatatui.Surface` — the contract a device implements: panel geometry in `init/1`, pixels out in `push/2`, input in through `send_event/2`. Most consumers only write this module.
    * `RasterExRatatui.Session` — the same app-on-a-raster without the process, for consumers that already own one: start it there, fold its messages with `handle/2`, write the patches.
    * `RasterExRatatui.Raster` — the pure rasteriser underneath: payloads in, patches or a frame out.
    * `RasterExRatatui.Font`, `RasterExRatatui.PixelFormat` — the two behaviours that make the output fit a panel: glyph bitmaps and pixel packing.
    * `RasterExRatatui.Framebuffer`, `RasterExRatatui.Input.Evdev` — optional helpers for Linux framebuffers and evdev keyboards.
    * `RasterExRatatui.Telemetry` — the events the surface emits.
  """
end
