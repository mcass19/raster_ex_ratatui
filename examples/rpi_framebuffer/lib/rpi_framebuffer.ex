defmodule RpiFramebuffer do
  @moduledoc """
  An ExRatatui dashboard on a Raspberry Pi's display, drawn through `/dev/fb0` by `raster_ex_ratatui`, with a USB keyboard. Any framebuffer works: the panel's size and depth are read at boot.

  On the device, `RpiFramebuffer.Surface` runs `RpiFramebuffer.Dashboard` on the framebuffer. On a laptop the same app runs in a terminal:

      iex -S mix
      iex> RpiFramebuffer.run()
  """

  @doc """
  Runs the dashboard in the current terminal and returns when it stops (`ctrl+q`, or `q` outside the Input tab).

  `opts` go to `RpiFramebuffer.Dashboard.start_link/1`: the app's own options plus the runtime's (`:name`, `:test_mode`).
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    {:ok, pid} = RpiFramebuffer.Dashboard.start_link(opts)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
