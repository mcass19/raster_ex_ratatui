defmodule RpiFramebuffer.MixProject do
  use Mix.Project

  @app :rpi_framebuffer
  @version "0.1.0"
  @all_targets [:rpi0_2, :rpi3, :rpi4, :rpi5]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      archives: [nerves_bootstrap: "~> 1.15"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {RpiFramebuffer.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      {:nerves_runtime, "~> 0.13.12"},

      # The library from this repository (ex_ratatui comes with it). Outside the
      # repository this is `{:raster_ex_ratatui, "~> 0.1"}`.
      {:raster_ex_ratatui, path: "../.."},

      # USB keyboard. Linux only; it compiles on a Linux host too, so the tests run there.
      {:input_event, "~> 1.4"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Dependencies for specific targets. Only :rpi4 has run on hardware.
      {:nerves_system_rpi0_2, "~> 2.1", runtime: false, targets: :rpi0_2},
      {:nerves_system_rpi3, "~> 2.1", runtime: false, targets: :rpi3},
      {:nerves_system_rpi4, "~> 2.1", runtime: false, targets: :rpi4},
      {:nerves_system_rpi5, "~> 2.1", runtime: false, targets: :rpi5}
    ]
  end

  def release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
