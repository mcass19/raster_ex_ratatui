defmodule RasterExRatatui.MixProject do
  use Mix.Project

  @description "Render ExRatatui apps on pixel displays such as e-ink panels and Linux framebuffers"
  @source_url "https://github.com/mcass19/raster_ex_ratatui"
  @changelog_url @source_url <> "/blob/main/CHANGELOG.md"
  @version "0.1.0"

  def project do
    [
      app: :raster_ex_ratatui,
      description: @description,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      name: "RasterExRatatui",
      homepage_url: @source_url,
      source_url: @source_url,
      docs: docs(),
      test_coverage: [
        summary: [threshold: 100],
        ignore_modules: [
          # Test fixtures — exercised by tests.
          ~r/^RasterExRatatui\.Test\./
        ]
      ],
      dialyzer: [
        plt_local_path: "plts",
        plt_core_path: "plts/core"
      ],
      usage_rules: usage_rules()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :telemetry]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_ratatui, "~> 0.14"},
      {:telemetry, "~> 1.0"},

      # Test
      {:stream_data, "~> 1.1", only: :test},

      # Dev
      {:usage_rules, "~> 1.2", only: [:dev]},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp usage_rules do
    [
      file: "AGENTS.md",
      skills: [
        location: ".claude/skills",
        build: [
          "elixir-core": [
            description:
              "Use this skill when writing or refactoring any Elixir code — core language idioms and OTP patterns.",
            usage_rules: [:usage_rules]
          ]
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => @changelog_url
      },
      keywords: ~w(tui ratatui ex_ratatui nerves framebuffer eink raster display),
      files: ~w(lib guides .formatter.exs mix.exs README.md LICENSE CHANGELOG.md usage-rules.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md": [title: "Overview"],
        "usage-rules.md": [title: "Usage Rules (for AI agents)"],
        "examples/README.md": [title: "Examples", filename: "examples"],
        "guides/surfaces.md": [title: "Building a Surface"],
        "guides/fonts.md": [title: "Fonts"],
        "guides/pixel_formats.md": [title: "Pixel Formats"],
        "guides/framebuffer.md": [title: "Linux Framebuffers"],
        "guides/telemetry.md": [title: "Telemetry"],
        "CONTRIBUTING.md": [title: "Contributing"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_extras: [
        Introduction: ["examples/README.md", "usage-rules.md"],
        Guides: ~r"guides/.+\.md"
      ],
      groups_for_modules: [
        Surface: [
          RasterExRatatui.Surface
        ],
        Core: [
          RasterExRatatui,
          RasterExRatatui.Session,
          RasterExRatatui.Raster,
          RasterExRatatui.Patch,
          RasterExRatatui.Grid,
          RasterExRatatui.Palette
        ],
        Fonts: [
          RasterExRatatui.Font,
          RasterExRatatui.Font.Default6x8,
          RasterExRatatui.Font.Art,
          RasterExRatatui.Font.Generated
        ],
        "Pixel formats": [
          RasterExRatatui.PixelFormat,
          RasterExRatatui.PixelFormat.Mono,
          RasterExRatatui.PixelFormat.RGB565,
          RasterExRatatui.PixelFormat.XRGB8888
        ],
        "Device helpers": [
          RasterExRatatui.Framebuffer,
          RasterExRatatui.Input.Devices,
          RasterExRatatui.Input.Evdev
        ],
        Internals: [
          RasterExRatatui.Telemetry
        ]
      ]
    ]
  end
end
