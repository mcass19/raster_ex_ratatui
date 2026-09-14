defmodule RasterExRatatui do
  @moduledoc """
  Render [ExRatatui](https://hexdocs.pm/ex_ratatui) apps on pixel displays such as e-ink panels, with helpers for Linux framebuffers.

  A terminal turns cells into pixels by itself. A bare panel does not, so something has to paint every cell's glyph in its colours, and blit the bitmaps that pixel-mode widgets (`ExRatatui.Widgets.Viewport3D`, `ExRatatui.Widgets.Image`) hand to an `ExRatatui.CellSession` created with a `:font_size`. This package is that something, in three layers:

      ┌──────────────────────────────────────────────────────────────┐
      │ Surface      use RasterExRatatui.Surface                     │
      │              owns the app server, folds diffs, calls push/2  │
      ├──────────────────────────────────────────────────────────────┤
      │ Raster       Grid (cells + regions) → [Patch] | full frame   │
      │              Font × Palette × PixelFormat × scale            │
      ├──────────────────────────────────────────────────────────────┤
      │ Device       Framebuffer (fbdev) · Input.Evdev (keyboards)   │
      │              or the consumer's own driver (SPI, e-ink, …)    │
      └──────────────────────────────────────────────────────────────┘

  ## Where to start

    * `RasterExRatatui.Surface` — the contract a device implements: panel geometry in `init/1`, pixels out in `push/2`, input in through `send_event/2`. Most consumers only write this module.
    * `RasterExRatatui.Raster` — the pure rasteriser underneath, for consumers that already own a process and a device loop.
    * `RasterExRatatui.Font`, `RasterExRatatui.PixelFormat` — the two behaviours that make the output fit a panel: glyph bitmaps and pixel packing.
    * `RasterExRatatui.Framebuffer`, `RasterExRatatui.Input.Evdev` — optional helpers for Linux framebuffers and evdev keyboards.
    * `RasterExRatatui.Telemetry` — the events the surface emits.
  """
end
