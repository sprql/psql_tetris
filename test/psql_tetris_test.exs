defmodule PsqlTetrisTest do
  use ExUnit.Case, async: true

  alias PsqlTetris.MigrationRewriter
  alias PsqlTetris.Optimizer
  alias PsqlTetris.Types

  describe "Types.rank/2" do
    test "8-byte fixed types" do
      assert Types.rank(:bigint) == 1
      assert Types.rank(:bigserial) == 1
      assert Types.rank(:utc_datetime_usec) == 1
      assert Types.rank(:float) == 1
    end

    test "4-byte fixed types" do
      assert Types.rank(:integer) == 2
      assert Types.rank(:date) == 2
      assert Types.rank(:uuid) == 2
      assert Types.rank(:binary_id) == 2
    end

    test "2-byte / 1-byte / varlena" do
      assert Types.rank(:smallint) == 3
      assert Types.rank(:boolean) == 4
      assert Types.rank(:string) == 5
      assert Types.rank(:text) == 5
      assert Types.rank(:map) == 5
      assert Types.rank({:array, :integer}) == 5
    end

    test "references default to 8-byte" do
      assert Types.rank({:references, []}) == 1
      assert Types.rank({:references, [type: :integer]}) == 2
      assert Types.rank({:references, [type: :uuid]}) == 2
      assert Types.rank({:references, [type: :binary_id]}) == 2
    end

    test "unknown types fall back to varlena" do
      assert Types.rank(:totally_made_up) == 5
    end
  end

  describe "Types.rank_pg_type/1 (catalog-driven path)" do
    test "8-byte fixed PG types" do
      assert Types.rank_pg_type("bigint") == 1
      assert Types.rank_pg_type("bigserial") == 1
      assert Types.rank_pg_type("timestamp") == 1
      assert Types.rank_pg_type("timestamp without time zone") == 1
      assert Types.rank_pg_type("double precision") == 1
    end

    test "4-byte fixed PG types" do
      assert Types.rank_pg_type("integer") == 2
      assert Types.rank_pg_type("date") == 2
      assert Types.rank_pg_type("uuid") == 2
      assert Types.rank_pg_type("real") == 2
    end

    test "2-byte / 1-byte / varlena" do
      assert Types.rank_pg_type("smallint") == 3
      assert Types.rank_pg_type("boolean") == 4
      assert Types.rank_pg_type("text") == 5
      assert Types.rank_pg_type("jsonb") == 5
      assert Types.rank_pg_type("numeric") == 5
      assert Types.rank_pg_type("bytea") == 5
    end

    test "strips size/precision suffixes" do
      assert Types.rank_pg_type("varchar(255)") == 5
      assert Types.rank_pg_type("numeric(10,2)") == 5
    end

    test "arrays are always varlena regardless of element type" do
      assert Types.rank_pg_type("integer[]") == 5
      assert Types.rank_pg_type("bigint[]") == 5
    end
  end

  describe "Optimizer.optimize/1" do
    test "orders by rank then NOT NULL then original index" do
      cols = [
        %{name: :flag, type: :boolean, opts: []},
        %{name: :email, type: :string, opts: []},
        %{name: :id_num, type: :bigint, opts: []},
        %{name: :age, type: :integer, opts: [null: false]},
        %{name: :ts, type: :utc_datetime, opts: [null: false]},
        %{name: :tiny, type: :smallint, opts: []}
      ]

      assert Enum.map(Optimizer.optimize(cols), & &1.name) ==
               [:ts, :id_num, :age, :tiny, :flag, :email]
    end

    test "stable within same rank+nullability" do
      cols = [
        %{name: :a, type: :string, opts: []},
        %{name: :b, type: :string, opts: []},
        %{name: :c, type: :string, opts: []}
      ]

      assert Enum.map(Optimizer.optimize(cols), & &1.name) == [:a, :b, :c]
    end

    test "keeps explicit primary keys before alignment-optimized columns" do
      cols = [
        %{name: :id, type: :uuid, opts: [primary_key: true]},
        %{name: :inserted_at, type: :utc_datetime, opts: [null: false]},
        %{name: :big, type: :bigint, opts: []}
      ]

      assert Enum.map(Optimizer.optimize(cols), & &1.name) == [:id, :inserted_at, :big]
    end

    test "non-primary UUIDs still rank normally" do
      cols = [
        %{name: :external_id, type: :uuid, opts: []},
        %{name: :inserted_at, type: :utc_datetime, opts: [null: false]}
      ]

      assert Enum.map(Optimizer.optimize(cols), & &1.name) == [:inserted_at, :external_id]
    end

    test "multiple explicit primary keys preserve author order before other columns" do
      cols = [
        %{name: :tenant_id, type: :uuid, opts: [primary_key: true]},
        %{name: :account_id, type: :bigint, opts: [primary_key: true]},
        %{name: :inserted_at, type: :utc_datetime, opts: [null: false]}
      ]

      assert Enum.map(Optimizer.optimize(cols), & &1.name) == [
               :tenant_id,
               :account_id,
               :inserted_at
             ]
    end
  end

  describe "MigrationRewriter.rewrite/1" do
    test "reorders a create table block" do
      input = """
      defmodule MyApp.Repo.Migrations.CreateUsers do
        use Ecto.Migration

        def change do
          create table(:users) do
            add :active, :boolean, null: false
            add :email, :string
            add :id_num, :bigint
            add :tiny, :smallint
          end
        end
      end
      """

      out = MigrationRewriter.rewrite(input)
      lines = String.split(out, "\n")

      assert idx(lines, "add :id_num") < idx(lines, "add :tiny")
      assert idx(lines, "add :tiny") < idx(lines, "add :active")
      assert idx(lines, "add :active") < idx(lines, "add :email")
    end

    test "preserves trailing newline" do
      input = "create table(:t) do\n  add :a, :string\n  add :b, :bigint\nend\n"
      out = MigrationRewriter.rewrite(input)
      assert String.ends_with?(out, "\n")
    end

    test "treats comments and blank lines as barriers" do
      input = """
      create table(:t) do
        add :email, :string
        # group A
        add :id_num, :bigint
        add :tiny, :smallint
      end
      """

      out = MigrationRewriter.rewrite(input)
      lines = String.split(out, "\n")

      # Within the second run id_num (8b) should come before tiny (2b).
      assert idx(lines, "add :id_num") < idx(lines, "add :tiny")

      # But the first run (single column `email`) is preserved above the comment.
      assert idx(lines, "add :email") < idx(lines, "# group A")
    end

    test "leaves non-add statements (timestamps, modify) in place" do
      input = """
      create table(:t) do
        add :flag, :boolean
        add :id_num, :bigint
        timestamps()
      end
      """

      out = MigrationRewriter.rewrite(input)
      lines = String.split(out, "\n")

      assert idx(lines, "add :id_num") < idx(lines, "add :flag")
      assert idx(lines, "add :flag") < idx(lines, "timestamps()")
    end

    test "handles alter table" do
      input = """
      alter table(:users) do
        add :flag, :boolean
        add :big_id, :bigint
      end
      """

      out = MigrationRewriter.rewrite(input)
      lines = String.split(out, "\n")

      assert idx(lines, "add :big_id") < idx(lines, "add :flag")
    end

    test "handles multi-line add calls" do
      input = """
      create table(:t) do
        add :flag,
            :boolean,
            null: false
        add :big, :bigint
      end
      """

      out = MigrationRewriter.rewrite(input)
      lines = String.split(out, "\n")

      assert idx(lines, "add :big") < idx(lines, "add :flag")
    end

    test "honors `# psql_tetris: skip` directive inside a block" do
      input = """
      create table(:legacy) do
        # psql_tetris: skip
        add :flag, :boolean
        add :email, :string
        add :id_num, :bigint
      end
      """

      assert MigrationRewriter.rewrite(input) == input
    end

    test "skip directive is scoped to the block it appears in" do
      input = """
      create table(:legacy) do
        # psql_tetris: skip
        add :flag, :boolean
        add :id_num, :bigint
      end

      create table(:fresh) do
        add :small_flag, :boolean
        add :big_id, :bigint
      end
      """

      out = MigrationRewriter.rewrite(input)

      [legacy_block, fresh_block] = String.split(out, "create table(:fresh)")

      # Legacy block (skipped) preserves original order: flag before id_num.
      assert :binary.match(legacy_block, "add :flag, :boolean") <
               :binary.match(legacy_block, "add :id_num, :bigint")

      # Fresh block (not skipped) gets reordered: bigint before boolean.
      assert :binary.match(fresh_block, "add :big_id, :bigint") <
               :binary.match(fresh_block, "add :small_flag, :boolean")
    end

    test "files without a table block are unchanged" do
      input = """
      defmodule Foo do
        def bar, do: :ok
      end
      """

      assert MigrationRewriter.rewrite(input) == input
    end
  end

  describe "Formatter plugin" do
    test "features advertises .exs" do
      assert PsqlTetris.Formatter.features([]) == [extensions: [".exs"]]
    end

    test "format/2 reorders migration files but leaves other files alone" do
      src = """
      create table(:t) do
        add :a, :boolean
        add :b, :bigint
      end
      """

      opts_pg = [psql_tetris: [enabled: true]]

      # Non-migration path: passthrough even on a PG project.
      assert PsqlTetris.Formatter.format(src, [file: "lib/foo.exs"] ++ opts_pg) == src

      # Migration path on PG project: reordered.
      rewritten =
        PsqlTetris.Formatter.format(
          src,
          [file: "priv/repo/migrations/20260222_create.exs"] ++ opts_pg
        )

      assert rewritten != src
      assert String.contains?(rewritten, "add :b, :bigint\n")
    end

    test "format/2 is a no-op when Postgrex is not loaded (non-PG project)" do
      src = """
      create table(:t) do
        add :a, :boolean
        add :b, :bigint
      end
      """

      # No explicit override; `Postgrex` is not loaded in this test env, so
      # the default gate denies the rewrite even for migration paths.
      refute Code.ensure_loaded?(Postgrex)

      assert PsqlTetris.Formatter.format(src,
               file: "priv/repo/migrations/20260222_create.exs"
             ) == src
    end

    test "format/2 honours explicit `enabled: false` override" do
      src = """
      create table(:t) do
        add :a, :boolean
        add :b, :bigint
      end
      """

      out =
        PsqlTetris.Formatter.format(src,
          file: "priv/repo/migrations/20260222_create.exs",
          psql_tetris: [enabled: false]
        )

      assert out == src
    end

    test "migration_file?/2 honours custom paths" do
      opts = [psql_tetris: [migration_paths: ["db/migrate/"]]]
      assert PsqlTetris.Formatter.migration_file?("apps/x/db/migrate/001.exs", opts)
      refute PsqlTetris.Formatter.migration_file?("priv/repo/migrations/001.exs", opts)
    end
  end

  defp idx(lines, substr), do: Enum.find_index(lines, &String.contains?(&1, substr))
end
