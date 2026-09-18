defmodule RpiFramebuffer.ApplicationTest do
  use ExUnit.Case, async: true

  alias RpiFramebuffer.Application, as: App

  test "starts nothing on the host, where no surface is configured" do
    assert Application.fetch_env(:rpi_framebuffer, RpiFramebuffer.Surface) == :error
    assert App.children(:error) == []
    assert Supervisor.which_children(RpiFramebuffer.Supervisor) == []
  end

  test "starts the configured surface under its module name" do
    assert App.children({:ok, [rotate: 90]}) ==
             [{RpiFramebuffer.Surface, [name: RpiFramebuffer.Surface, rotate: 90]}]
  end
end
