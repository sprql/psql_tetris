# PsqlTetris

![psql_tetris logo](assets/psql_tetris.png)

[![Hex.pm](https://img.shields.io/hexpm/v/psql_tetris.svg)](https://hex.pm/packages/psql_tetris)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/psql_tetris)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Mix formatter plugin that reorders columns in **Ecto migrations** for optimal PostgreSQL column alignment: less padding between values, fewer wasted bytes per row, smaller tables on big writes.

Full docs: <https://hexdocs.pm/psql_tetris>.

Inspired by [pg_column_byte_packer](https://github.com/braintree/pg_column_byte_packer), a Ruby Gem,  and [rogerwelin/pg_column_tetris](https://github.com/rogerwelin/pg_column_tetris). The `pg_column_tetris` project is a SQL extension that runs at `CREATE TABLE` time inside Postgres. `PsqlTetris` instead operates at the source-code level inside your Elixir / Phoenix / Ecto project, so the optimization happens the moment a developer runs `mix format` on a new migration, before the table is ever created.

## Why column order matters

PostgreSQL aligns each column value to a natural boundary on disk (8-byte values land on 8-byte boundaries, 4-byte on 4-byte boundaries, etc.). Padding bytes are silently inserted between columns to make that happen. A table written in "human" order:

```sql
boolean, text, bigint, smallint, integer
```

can waste several bytes per row on padding. The same columns reordered largest-alignment-first leave no holes.

## Only runs on PostgreSQL projects

The reordering algorithm follows from how PostgreSQL aligns column values on disk (per-column alignment classes, the varlena tail). It does **not** apply to MySQL/MariaDB (no per-column alignment to optimize), SQLite (dynamic typing, no fixed column slots), or MSSQL.

`PsqlTetris.Formatter` therefore gates itself on the presence of the `Postgrex` driver module in the project. `Postgrex` is the canonical Postgres driver for Elixir and is only declared as a dependency, so its presence is a reliable signal. Note that checking for `Ecto.Adapters.Postgres` alone would be insufficient: `ecto_sql` ships the adapter modules for several databases bundled together.

If you need to override the auto-detection (unusual setup, tooling-only project that doesn't ship Postgrex, CI environment):

```elixir
# .formatter.exs
psql_tetris: [enabled: true]  # or false
```

## Installation

Add `:psql_tetris` to `deps/0` in your project's `mix.exs`:

```elixir
def deps do
  [
    {:psql_tetris, "~> 0.1.3", only: [:dev], runtime: false}
  ]
end
```

Where the plugin goes depends on your project layout.

### Phoenix / Ecto projects (most common)

`mix phx.new` generates a *second* `.formatter.exs` inside `priv/repo/migrations/`, registered in the root one as `subdirectories: ["priv/*/migrations"]`. For any file under that path, `mix format` uses *only* the subdirectory config; the root config (and its `:plugins`) is ignored. So the plugin belongs there:

```elixir
# priv/repo/migrations/.formatter.exs
[
  import_deps: [:ecto_sql],
  plugins: [PsqlTetris.Formatter],
  inputs: ["*.exs"]
]
```

You do **not** need to add anything to the root `.formatter.exs`. The default Phoenix root `inputs:` doesn't cover migrations anyway, so a `plugins:` entry there would never fire on a migration.

### Non-Phoenix projects (no migrations subdirectory)

If your project keeps everything under a single `.formatter.exs` (no `subdirectories:` split), add the plugin in the root and make sure `inputs:` covers your migration path:

```elixir
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,priv}/**/*.{ex,exs}"],
  plugins: [PsqlTetris.Formatter]
]
```

### Custom migration paths

By default the plugin treats any file whose path contains `priv/repo/migrations/` or `/migrations/` as a migration. Override if needed:

```elixir
psql_tetris: [
  migration_paths: ["priv/repo/migrations/", "apps/*/priv/repo/migrations/"]
]
```

## What it does

Given:

```elixir
create table(:users) do
  add :active, :boolean, null: false
  add :email, :string
  add :id_num, :bigint
  add :tiny, :smallint
  add :inserted_at, :utc_datetime, null: false
end
```

`mix format` rewrites it to:

```elixir
create table(:users) do
  add :inserted_at, :utc_datetime, null: false
  add :id_num, :bigint
  add :tiny, :smallint
  add :active, :boolean, null: false
  add :email, :string
end
```

Within an alignment group, `null: false` columns come first (a small CPU win during tuple deforming).

## Rules

* Only `add/2,3` calls inside `create table` and `alter table` blocks are touched.
* `modify/3`, `remove/2`, `timestamps/0`, comments, and blank lines act as **barriers**: they are never moved, and they split surrounding `add` runs into independent groups. This preserves intentional grouping by the author.
* Files that don't look like migrations (per `migration_paths`) are passed through unchanged.

## Opting out per block

If a particular block must not be reordered (legacy table, intentional ordering tied to a specific index, reproducing a `pg_dump` layout, etc.), add a `# psql_tetris: skip` comment anywhere inside it:

```elixir
create table(:legacy_events) do
  # psql_tetris: skip
  add :payload, :map
  add :flag, :boolean
  add :ts, :utc_datetime
end
```

The marker is scoped to the block it appears in; other blocks in the same file are still reordered normally.

The opt-out-via-comment idea is borrowed from Angelika Cathor's [Markdown code-block formatter plugin][angelika], which uses the same pattern to skip individual blocks.

[angelika]: https://angelika.me/2024/01/27/format-elixir-code-blocks-in-markdown/

## How types are classified

`PsqlTetris` uses a two-layer strategy so it stays accurate without duplicating logic from Ecto:

1. **Delegate to Ecto when available.** If `Ecto.Adapters.Postgres.Connection` is loaded (always true inside a Phoenix/Ecto project), we ask Ecto itself to render the PG column type via `column_type/2`, then look up the resulting PG type name (`bigint`, `timestamp`, `uuid`, ...) in the PostgreSQL catalog alignment table. This way we always match whatever Ecto version your project happens to use, with no duplicated mapping for us to keep in sync.
2. **Static fallback** when Ecto isn't loaded (running stand-alone). Mirrors Ecto's documented mapping for the common types.

Either path returns a rank 1-5:

| Rank | PG alignment    | Examples (PG types)                                  |
|------|-----------------|------------------------------------------------------|
| 1    | 8-byte fixed    | `bigint`, `bigserial`, `timestamp[tz]`, `float8`, `interval`, `money` |
| 2    | 4-byte fixed    | `integer`, `serial`, `date`, `time`, `real`, `uuid`  |
| 3    | 2-byte fixed    | `smallint`, `smallserial`                            |
| 4    | 1-byte fixed    | `boolean`, `"char"`                                  |
| 5    | variable length | `text`, `varchar`, `numeric`, `jsonb`, `bytea`, arrays |

Unknown types fall back to rank 5 (varlena), which is the safe end of the table.

> **Note:** `ecto_sql` is **not** declared as a runtime dep of `psql_tetris`, so adding the plugin never forces a particular Ecto version on you. Detection is purely at call time via `Code.ensure_loaded?/1`.

## Programmatic use

```elixir
PsqlTetris.optimize_migration(File.read!("priv/repo/migrations/..."))
```

## License

Released under the [MIT License](LICENSE).
