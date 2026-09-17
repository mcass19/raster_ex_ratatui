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
  #
  # A surface is :transient by default, so an app that quits stays stopped. On
  # a panel with nothing else to show, quitting restarts the dashboard instead.
  def children({:ok, opts}) do
    [Supervisor.child_spec({RpiFramebuffer.Surface, opts}, restart: :permanent)]
  end

  def children(:error), do: []
end
