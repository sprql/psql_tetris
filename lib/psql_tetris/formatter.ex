defmodule PsqlTetris.Formatter do
  @moduledoc """
  Mix formatter plugin.

  Add this module to the `:plugins` list of your project's `.formatter.exs` and `mix format` will quietly reorder columns in new (and existing) Ecto migrations using PostgreSQL layout metadata:

      # .formatter.exs
      [
        inputs: ["{mix,.formatter}.exs", "{config,lib,test,priv}/**/*.{ex,exs}"],
        plugins: [PsqlTetris.Formatter],
        psql_tetris: [
          migration_paths: ["priv/repo/migrations/", "priv/*/migrations/"]
        ]
      ]

  Only `.exs` files whose path matches one of the configured migration paths are rewritten. Every other file is returned untouched. The default match is anything containing `priv/` and `/migrations/` in the path, which covers the standard Phoenix/Ecto layout.

  ## Safety: only runs on PostgreSQL projects

  The reordering argument follows from how PostgreSQL aligns column values on disk (per-column alignment classes, the varlena tail). It does not apply to MySQL or MariaDB (no per-column alignment to optimize), SQLite (dynamic typing, no fixed column slots), or MSSQL. Running this formatter against a non-Postgres project would shuffle columns for no benefit, so by default it won't.

  Detection is done at format time by checking whether the `Postgrex` driver module is loaded in the project. `Postgrex` is the canonical Postgres driver for Elixir and only shows up as a dep on actual Postgres projects, so its presence is a reliable signal. Checking for `Ecto.Adapters.Postgres` alone would not be enough, because `ecto_sql` bundles adapter modules for several databases together.

  If you have an unusual setup (e.g. a tooling-only project that doesn't ship Postgrex), you can force the plugin on or off explicitly:

      psql_tetris: [enabled: true | false]

  in `.formatter.exs`.

  Unknown/custom migration types default to conservative varlena layout. If your project uses custom PostgreSQL enums for otherwise-unknown atoms, configure their physical layout globally:

      psql_tetris: [unknown_type_layout: {:fixed, 4, 4}]

  Blank lines split reorderable column runs by default. If your migrations use
  blank lines as visual spacing rather than semantic grouping, ignore and remove
  them inside reorderable runs instead:

      psql_tetris: [blank_lines: :ignore]
  """

  @behaviour Mix.Tasks.Format

  alias PsqlTetris.MigrationRewriter

  @impl true
  def features(_opts) do
    [extensions: [".exs"]]
  end

  @impl true
  def format(contents, opts) do
    file = Keyword.get(opts, :file, "")

    if enabled?(opts) and migration_file?(file, opts) do
      MigrationRewriter.rewrite(contents, config(opts))
    else
      contents
    end
  end

  @doc false
  def enabled?(opts) do
    opts
    |> Keyword.get(:psql_tetris, [])
    |> Keyword.get(:enabled, postgres_project?())
  end

  defp postgres_project?, do: Code.ensure_loaded?(Postgrex)

  defp config(opts), do: Keyword.get(opts, :psql_tetris, [])

  @doc false
  def migration_file?(file, opts) when is_binary(file) do
    paths = opts |> config() |> Keyword.get(:migration_paths, default_paths())

    Enum.any?(paths, fn pattern ->
      if String.contains?(pattern, "*") do
        path_matches_glob?(file, pattern)
      else
        String.contains?(file, pattern)
      end
    end)
  end

  def migration_file?(_, _), do: false

  defp default_paths do
    ["priv/repo/migrations/", "/migrations/"]
  end

  defp path_matches_glob?(file, pattern) do
    # Treat pattern as a shell-ish glob: convert to regex.
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.match?(~r/#{regex}/, file)
  end
end
