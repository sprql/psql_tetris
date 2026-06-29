# Changelog

All notable changes to `psql_tetris` are documented in this file. Format
loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [SemVer](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-06-28

### Changed

* Simplified layout resolution to deterministic static metadata exposed through
  `PsqlTetris.Layout.resolve/2`.
* Removed the dynamic Ecto Postgres type-rendering path and the legacy
  `from_pg_type/1` and `inferred_varlena/0` layout APIs.

## [0.1.3] - 2026-06-25

### Changed

* Explicit primary key columns (`primary_key: true`) now stay at the front
  of their contiguous `add` run before alignment sorting is applied to the
  remaining columns. This matches Ecto's implicit primary key convention and
  keeps UUID/Binary ID primary keys readable.

## [0.1.2] - 2026-05-22

Fixing docs.

## [0.1.1] - 2026-05-22

### Changed

* a smol' correction re terminology. Now aligned across `mix.exs` description,
  README, `CHANGELOG` and module docs: the tool optimizes **PostgreSQL column alignment**
  (the row-layout improvement is the consequence, not the goal).

### Fixed

* Removed an inaccurate "copy-pasteable" doctest from `PsqlTetris` and
  replaced it with a plain Elixir code block. The previous example
  included `iex>` continuation prefixes that were not safe to paste
  into an IEx session as-is.

## [0.1.0] - 2026-05-22

Initial release.

### Added

* `PsqlTetris.Formatter`: `Mix.Tasks.Format` plugin that reorders columns
  in Ecto migration files for optimal PostgreSQL column alignment.
* `PsqlTetris.Types`: Two-layer type classification. Delegates to
  `Ecto.Adapters.Postgres.Connection.column_type/2` when Ecto is loaded,
  with a static fallback table mirroring Ecto's documented mapping.
* `PsqlTetris.MigrationRewriter`: Text-level rewriter that only touches
  `add/2,3` calls inside `create table` and `alter table` blocks. Other
  statements (`modify`, `remove`, `timestamps`, comments, blank lines)
  act as semantic barriers.
* `PsqlTetris.Column`: Source-preserving column representation with stable
  sort by physical layout and `null: false` tie-breaking.
* Per-block opt-out via `# psql_tetris: skip` comment.
* PostgreSQL-only safety gate: detects the host project's database engine
  through the presence of the `Postgrex` driver module and refuses to
  run on MySQL/SQLite/MSSQL projects unless explicitly overridden.
* Configuration knobs in `.formatter.exs`:
  * `migration_paths` (glob list, default `["priv/repo/migrations/", "/migrations/"]`).
  * `enabled` (`true | false`, default: auto-detect via `Postgrex`).

[0.2.0]: https://github.com/florinpatrascu/psql_tetris/releases/tag/v0.2.0
[0.1.3]: https://github.com/florinpatrascu/psql_tetris/releases/tag/v0.1.3
[0.1.2]: https://github.com/florinpatrascu/psql_tetris/releases/tag/v0.1.2
[0.1.1]: https://github.com/florinpatrascu/psql_tetris/releases/tag/v0.1.1
[0.1.0]: https://github.com/florinpatrascu/psql_tetris/releases/tag/v0.1.0
