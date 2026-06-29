# PsqlTetris

![psql_tetris logo](assets/psql_tetris.png)

[![Hex.pm](https://img.shields.io/hexpm/v/psql_tetris.svg)](https://hex.pm/packages/psql_tetris)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/psql_tetris)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Mix formatter plugin that reorders columns in **Ecto migrations** using PostgreSQL layout metadata and a fixed-width-first layout heuristic: less padding between fixed-width values, fewer wasted bytes per row, smaller tables on big writes.

Full docs: <https://hexdocs.pm/psql_tetris>.

Inspired by [pg_column_byte_packer](https://github.com/braintree/pg_column_byte_packer), a Ruby Gem,  and [rogerwelin/pg_column_tetris](https://github.com/rogerwelin/pg_column_tetris). The `pg_column_tetris` project is a SQL extension that runs at `CREATE TABLE` time inside Postgres. `PsqlTetris` instead operates at the source-code level inside your Elixir / Phoenix / Ecto project, so the optimization happens the moment a developer runs `mix format` on a new migration, before the table is ever created.

## Why column order matters

PostgreSQL aligns each column value to a natural boundary on disk (8-byte values land on 8-byte boundaries, 4-byte on 4-byte boundaries, etc.). Padding bytes are silently inserted between columns to make that happen. A table written in "human" order:

```sql
boolean, text, bigint, smallint, integer
```

can waste several bytes per row on padding. The same fixed-width columns reordered largest-alignment-first reduce those holes. Variable-length columns such as `text`/`jsonb` are handled conservatively as a tail because their exact inline size is data-dependent.

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
    {:psql_tetris, "~> 0.2.0", only: [:dev], runtime: false}
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
  inputs: ["*.exs"],
  psql_tetris: [
    # optional project-specific settings go here
    # unknown_type_layout: {:fixed, 4, 4}
  ]
]
```

Put `psql_tetris:` options in the same `.formatter.exs` that contains `plugins: [PsqlTetris.Formatter]`. In a standard Phoenix project, that means `priv/repo/migrations/.formatter.exs`, not the root formatter config. For files under a formatter `subdirectories:` entry, Mix uses the subdirectory config only; root-level plugin options are not applied to those files.

You do **not** need to add anything to the root `.formatter.exs` unless your root formatter is the one that actually formats migration files. The default Phoenix root `inputs:` doesn't cover migrations anyway, so a `plugins:` entry there would never fire on a migration.

### Non-Phoenix projects (no migrations subdirectory)

If your project keeps everything under a single `.formatter.exs` (no `subdirectories:` split), add the plugin in the root and make sure `inputs:` covers your migration path:

```elixir
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,priv}/**/*.{ex,exs}"],
  plugins: [PsqlTetris.Formatter],
  psql_tetris: [
    # optional project-specific settings go here
    # unknown_type_layout: {:fixed, 4, 4}
  ]
]
```

### Custom migration paths

By default the plugin treats any file whose path contains `priv/repo/migrations/` or `/migrations/` as a migration. Override if needed:

```elixir
psql_tetris: [
  migration_paths: ["priv/repo/migrations/", "apps/*/priv/repo/migrations/"]
]
```

### Unknown custom types

Built-in Ecto/PostgreSQL types are recognized automatically. Project-specific atoms are ambiguous when formatting offline:

```elixir
add(:role, :user_role, null: false)
add(:subject_type, :message_subject_type, null: false)
```

By default, unknown/custom atoms use conservative varlena layout. That is safest for domains, extensions, composite/custom types, and anything whose physical storage is not known to the formatter.

If your project's otherwise-unknown migration atoms are PostgreSQL enums, configure their fixed 4-byte layout globally in the formatter config that formats migrations:

```elixir
# priv/repo/migrations/.formatter.exs in standard Phoenix projects
[
  import_deps: [:ecto_sql],
  plugins: [PsqlTetris.Formatter],
  inputs: ["*.exs"],
  psql_tetris: [
    unknown_type_layout: {:fixed, 4, 4}
  ]
]
```

For single-formatter projects, put the same `psql_tetris:` block in the root `.formatter.exs` instead.

PostgreSQL enums are fixed-width 4-byte values with 4-byte alignment, represented as `{:fixed, 4, 4}`. This can avoid noisy or suboptimal ordering for enum-heavy schemas, while preserving the conservative default for projects with mixed custom types.

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
* `modify/3`, `remove/2`, comments, and blank lines act as **barriers** by default: they are never moved, and they split surrounding column runs into independent groups. This preserves intentional grouping by the author.
* `timestamps/0,1` is reordered with `add/2,3` calls. If you use blank lines as visual spacing rather than semantic grouping, configure `psql_tetris: [blank_lines: :ignore]` to let sortable columns cross blank lines and remove those blanks from the reordered run.
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

## PostgreSQL layout model

`PsqlTetris` models column layout from PostgreSQL physical storage metadata. Internally it keeps only the facts needed for ordering:

| Field | Meaning |
|-------|---------|
| `kind` | `:fixed` for fixed-width values, `:varlena` for variable-length values |
| `width` | Fixed byte width, or `nil` for varlena values |
| `align_bytes` | Required byte alignment: 8, 4, 2, or 1 |

This distinction matters because common varlena types are still 4-byte aligned:

| PG type | `kind` | `width` | `align_bytes` |
|---------|--------|---------|---------------|
| `bool` | `:fixed` | `1` | `1` |
| `int8` | `:fixed` | `8` | `8` |
| `int4` | `:fixed` | `4` | `4` |
| `text` | `:varlena` | `nil` | `4` |
| `jsonb` | `:varlena` | `nil` | `4` |
| `numeric` | `:varlena` | `nil` | `4` |

The default ordering policy is conservative:

1. explicit primary keys first;
2. fixed-width columns by descending physical alignment/width;
3. variable-length columns in a conservative tail;
4. references stay high when doing so is padding-equivalent;
5. unknown/custom types as inferred varlena, 4-byte aligned, unless `unknown_type_layout: {:fixed, width, align_bytes}` is configured;
6. `null: false` only as a tie-breaker inside equivalent physical buckets.

Varlena ordering is necessarily heuristic because the exact inline size of a `text`, `jsonb`, `numeric`, etc. value is row-dependent. The formatter is pure/offline: it uses static metadata for built-in/common types and does not query your database during `mix format`.

> **Note:** `ecto_sql` is **not** declared as a runtime dep of `psql_tetris`, so adding the plugin never forces a particular Ecto version on you. Detection is purely at call time via `Code.ensure_loaded?/1`.

## Programmatic use

```elixir
PsqlTetris.optimize_migration(File.read!("priv/repo/migrations/..."))
```

Pass formatter options directly when calling programmatically:

```elixir
PsqlTetris.optimize_migration(source, unknown_type_layout: {:fixed, 4, 4})
```

## License

Released under the [MIT License](LICENSE).
