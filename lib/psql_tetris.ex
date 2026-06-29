defmodule PsqlTetris do
  @moduledoc """
  PostgreSQL column-tetris formatter for Ecto migrations.

  This package ships a `Mix.Tasks.Format` plugin (`PsqlTetris.Formatter`) that rewrites Ecto migration files using PostgreSQL layout metadata and a conservative fixed-width-first heuristic. PostgreSQL aligns column values on natural boundaries and slips padding in between, and a "tetris-friendly" column order keeps those gaps small.

  See `PsqlTetris.Formatter` for installation and configuration. You can also call `optimize_migration/2` directly on a migration source string.
  """

  alias PsqlTetris.Column
  alias PsqlTetris.Layout
  alias PsqlTetris.LayoutSimulation
  alias PsqlTetris.MigrationParser
  alias PsqlTetris.MigrationRewriter

  @doc ~S'''
  Reorders the columns of every `create table` / `alter table` block in the given Elixir migration source string.

  ## Example

  ```elixir
  source = """
  defmodule MyApp.Repo.Migrations.CreateUsers do
    use Ecto.Migration

    def change do
      create table(:users) do
        add :active, :boolean, null: false
        add :email, :string
        add :id_num, :bigint
      end
    end
  end
  """

  PsqlTetris.optimize_migration(source) |> IO.puts()
  ```
  '''
  @spec optimize_migration(String.t(), keyword()) :: String.t()
  def optimize_migration(source, opts \\ []) when is_binary(source) do
    MigrationRewriter.rewrite(source, opts)
  end

  @doc """
  Simulates current and optimized PostgreSQL tuple layouts for each migration table block.

  Returns one comparison per discovered `create table` / `alter table` block.
  Each `PsqlTetris.LayoutSimulation.Comparison` contains `:current`, `:sorted`,
  and `:simulated_best` simulations. Lower `padding_width`, `data_width`, and
  `hot_path_score` values are better for the corresponding dimension.
  """
  @spec simulate_migration(String.t(), keyword()) :: [LayoutSimulation.Comparison.t()]
  def simulate_migration(source, opts \\ []) when is_binary(source) do
    lines = String.split(source, "\n")

    source
    |> MigrationParser.table_blocks()
    |> Enum.map(fn %{do_line: do_line, end_line: end_line} ->
      body_start = do_line + 1
      body_end = end_line - 1

      lines
      |> Enum.slice((body_start - 1)..(body_end - 1)//1)
      |> MigrationRewriter.simulate_body(opts)
    end)
  end

  @doc """
  Simulates PostgreSQL tuple layout for explicit column specs.

  Column specs may be `PsqlTetris.Column` structs or `{name, type}` /
  `{name, type, add_opts}` tuples using the same type vocabulary as Ecto
  migrations.
  """
  @spec simulate_columns([Column.t() | {term(), term()} | {term(), term(), keyword()}], keyword()) ::
          LayoutSimulation.t()
  def simulate_columns(column_specs, opts \\ []) when is_list(column_specs) do
    column_specs
    |> Enum.map(&normalize_column_spec(&1, opts))
    |> LayoutSimulation.simulate(opts)
  end

  defp normalize_column_spec(%Column{} = column, _opts), do: column

  defp normalize_column_spec({name, type}, opts),
    do: normalize_column_spec({name, type, []}, opts)

  defp normalize_column_spec({name, type, add_opts}, opts) when is_list(add_opts) do
    %Column{
      name: name,
      migration_type: type,
      layout: Layout.resolve(type, add_opts, opts),
      primary_key?: Keyword.get(add_opts, :primary_key) == true,
      reference?: match?({:references, _}, type),
      nullable?: Keyword.get(add_opts, :null) != false,
      source_lines: []
    }
  end
end
