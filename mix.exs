defmodule PsqlTetris.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/florinpatrascu/psql_tetris"
  @description "Mix formatter plugin that reorders Ecto migration columns using PostgreSQL layout metadata"

  def project do
    [
      app: :psql_tetris,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: @description,
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,
      name: "PsqlTetris"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    # No runtime deps: layout resolution is deterministic and offline, using
    # static metadata in `PsqlTetris.Layout`.
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Inspiration: pg_column_tetris" => "https://github.com/rogerwelin/pg_column_tetris"
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs assets)
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/psql_tetris.png",
      assets: %{"assets" => "assets"},
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "LICENSE"]
      ],
      groups_for_modules: [
        "Mix integration": [PsqlTetris.Formatter],
        Core: [PsqlTetris, PsqlTetris.MigrationRewriter, PsqlTetris.Column],
        "Type system": [PsqlTetris.Layout, PsqlTetris.LayoutSimulation]
      ],
      formatters: ["html"],
      authors: ["Florin T.Pătrașcu"]
    ]
  end
end
