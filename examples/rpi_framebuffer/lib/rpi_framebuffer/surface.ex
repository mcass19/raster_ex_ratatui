defmodule RpiFramebuffer.Surface do
  @moduledoc """
  The panel: `/dev/fb0` for pixels, the first USB keyboard for input, everything about the display read from the device at boot.

  `config :rpi_framebuffer, RpiFramebuffer.Surface` in `config/target.exs` holds the options, all of `RasterExRatatui.Framebuffer.Surface`'s: `rotate:` for the stand, `scale:`, `console:`, `keyboard:`, `touch:`, and `app_opts: [spin_ms: ...]` for the dashboard.
  """

  use RasterExRatatui.Framebuffer.Surface, app: RpiFramebuffer.Dashboard
end
