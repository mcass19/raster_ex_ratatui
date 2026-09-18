defmodule RpiFramebuffer.ApplicationTest do
  use ExUnit.Case, async: true

  alias RpiFramebuffer.Application, as: App

  test "starts nothing on the host, where no surface is configured" do
    assert Application.fetch_env(:rpi_framebuffer, RpiFramebuffer.Surface) == :error
    assert App.children(:error) == []
    assert Supervisor.which_children(RpiFramebuffer.Supervisor) == []
  end

  test "starts the configured surface and restarts it when the dashboard quits" do
    assert [%{id: RpiFramebuffer.Surface, restart: :permanent, start: start}] =
             App.children({:ok, [scale: 3]})

    assert start ==
             {RpiFramebuffer.Surface, :start_link, [[name: RpiFramebuffer.Surface, scale: 3]]}
  end
end
