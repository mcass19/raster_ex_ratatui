defmodule RpiFramebuffer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: RpiFramebuffer.Supervisor]
    surface = Application.fetch_env(:rpi_framebuffer, RpiFramebuffer.Surface)
    Supervisor.start_link(children(surface), opts)
  end

  @doc false
  # `config/target.exs` configures the surface; the host has no framebuffer to
  # own and runs the dashboard in a terminal via RpiFramebuffer.run/0.
  def children({:ok, opts}) do
    # Registered under its module name, so IEx can reach it:
    # RasterExRatatui.Telemetry.probe(RpiFramebuffer.Surface, 10)
    [{RpiFramebuffer.Surface, Keyword.put_new(opts, :name, RpiFramebuffer.Surface)}]
  end

  def children(:error), do: []
end
