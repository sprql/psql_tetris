defmodule PsqlTetrisTest do
  use ExUnit.Case, async: true

  alias PsqlTetris.Layout
  alias PsqlTetris.LayoutSimulation
  alias PsqlTetris.MigrationParser
  alias PsqlTetris.MigrationRewriter

  describe "static type layout" do
    test "separates variable length from alignment" do
      assert %Layout{kind: :varlena, width: nil, align_bytes: 4} = Layout.resolve("text", [])
      assert %Layout{kind: :fixed, width: 1, align_bytes: 1} = Layout.resolve("bool", [])
    end

    test "resolves common Ecto migration types" do
      assert %Layout{kind: :fixed, width: 8, align_bytes: 8} = Layout.resolve(:bigint, [])
      assert %Layout{kind: :varlena, width: nil, align_bytes: 4} = Layout.resolve(:string, [])
      assert %Layout{kind: :varlena, width: nil, align_bytes: 4} = Layout.resolve(:map, [])
    end

    test "references resolve through referenced key type" do
      assert %Layout{kind: :fixed, width: 8, align_bytes: 8} =
               Layout.resolve({:references, []}, [])

      assert %Layout{kind: :fixed, width: 16, align_bytes: 1} =
               Layout.resolve({:references, [type: :uuid]}, [])
    end

    test "arrays and unknown custom types are varlena 4-byte aligned" do
      assert %Layout{kind: :varlena, width: nil, align_bytes: 4} =
               Layout.resolve({:array, :integer}, [])

      assert %Layout{kind: :varlena, width: nil, align_bytes: 4} =
               Layout.resolve("numeric(10,2)[]", [])

      assert %Layout{kind: :varlena, width: nil, align_bytes: 4} =
               Layout.resolve(:made_up_extension_type, [])
    end

    test "unknown custom types can use a configured fixed layout" do
      assert %Layout{kind: :fixed, width: 4, align_bytes: 4} =
               Layout.resolve(:made_up_extension_type, [], unknown_type_layout: {:fixed, 4, 4})
    end

    test "custom type layouts resolve otherwise-unknown types" do
      opts = [custom_type_layouts: [user_role: {:fixed, 4, 4}, "weird type": :varlena]]

      assert %Layout{kind: :fixed, width: 4, align_bytes: 4} =
               Layout.resolve(:user_role, [], opts)

      assert %Layout{kind: :varlena, width: nil, align_bytes: 4} =
               Layout.resolve("weird type", [], opts)
    end

    test "citext remains varlena even when unknown custom types use a fixed layout" do
      assert %Layout{kind: :varlena, width: nil, align_bytes: 4} =
               Layout.resolve(:citext, [], unknown_type_layout: {:fixed, 4, 4})

      assert %Layout{kind: :varlena, width: nil, align_bytes: 4} =
               Layout.resolve("citext", [], unknown_type_layout: {:fixed, 4, 4})
    end
  end

  describe "MigrationRewriter.reorder_body/1 column ordering" do
    test "orders primary keys, fixed-width columns, then varlena tail" do
      lines = [
        "  add :body, :text",
        "  add :flag, :boolean",
        "  add :big, :bigint",
        "  add :count, :integer, null: false"
      ]

      assert add_names(MigrationRewriter.reorder_body(lines)) == [:big, :count, :flag, :body]
    end

    test "keeps explicit primary keys before layout-optimized columns" do
      lines = [
        "  add :tenant_id, :uuid, primary_key: true",
        "  add :account_id, :bigint, primary_key: true",
        "  add :inserted_at, :utc_datetime, null: false",
        "  add :big, :bigint"
      ]

      assert add_names(MigrationRewriter.reorder_body(lines)) == [
               :tenant_id,
               :account_id,
               :inserted_at,
               :big
             ]
    end

    test "preserves author order inside equivalent varlena tail" do
      lines = [
        "  add :body, :text",
        "  add :amount, :decimal",
        "  add :payload, :map"
      ]

      assert add_names(MigrationRewriter.reorder_body(lines)) == [:body, :amount, :payload]
    end

    test "null false is only a tie-breaker inside equivalent layout buckets" do
      lines = [
        "  add :a, :integer",
        "  add :b, :integer, null: false",
        "  add :c, :bigint"
      ]

      assert add_names(MigrationRewriter.reorder_body(lines)) == [:c, :b, :a]
    end

    test "keeps uuid references high when doing so is padding-equivalent" do
      lines = [
        "  add :state, :integer, null: false",
        "  add :user_id, references(:users, type: :binary_id), null: false",
        "  add :count, :integer"
      ]

      assert add_names(MigrationRewriter.reorder_body(lines)) == [:user_id, :state, :count]
    end

    test "still moves 8-byte columns ahead of uuid references when padding can improve" do
      lines = [
        "  add :state, :integer, null: false",
        "  add :user_id, references(:users, type: :binary_id), null: false",
        "  add :expires_at, :utc_datetime_usec, null: false"
      ]

      assert add_names(MigrationRewriter.reorder_body(lines)) == [:expires_at, :user_id, :state]
    end

    test "can treat unknown custom atoms as PostgreSQL enums" do
      lines = [
        "  add :body, :text, null: false",
        "  add :kind, :custom_status, null: false"
      ]

      assert add_names(MigrationRewriter.reorder_body(lines)) == [:body, :kind]

      assert add_names(MigrationRewriter.reorder_body(lines, unknown_type_layout: {:fixed, 4, 4})) ==
               [
                 :kind,
                 :body
               ]
    end
  end

  describe "LayoutSimulation" do
    test "reports padding and hot-path score for an ordered column list" do
      simulation =
        PsqlTetris.simulate_columns(
          [
            {:flag, :boolean},
            {:seen_at, :utc_datetime_usec},
            {:body, :text}
          ],
          access_weights: %{flag: 10, seen_at: 1},
          varlena_width: 12
        )

      assert %LayoutSimulation{data_width: 28, padding_width: 7, hot_path_score: 9} = simulation
      assert [:flag, :seen_at, :body] == Enum.map(simulation.placed_columns, & &1.column.name)
      assert [0, 8, 16] == Enum.map(simulation.placed_columns, & &1.offset)
    end

    test "compares current migration order with psql_tetris sorted order" do
      input = """
      create table(:t) do
        add :flag, :boolean
        add :seen_at, :utc_datetime_usec
        add :body, :text
      end
      """

      assert [%{current: current, sorted: sorted, simulated_best: simulated_best}] =
               PsqlTetris.simulate_migration(input)

      assert current.padding_width == 7
      assert sorted.padding_width == 3
      assert simulated_best.padding_width == 0
      assert [:seen_at, :flag, :body] == Enum.map(sorted.placed_columns, & &1.column.name)
      assert [:seen_at, :body, :flag] == Enum.map(simulated_best.placed_columns, & &1.column.name)
    end
  end

  describe "MigrationParser.table_blocks/1" do
    test "finds multiline and create_if_not_exists table blocks" do
      source = """
      def change do
        create table(
          :users,
          primary_key: false
        ) do
          add :flag, :boolean
          add :big, :bigint
        end

        create_if_not_exists table(:posts) do
          add :body, :text
          add :published, :boolean
        end
      end
      """

      assert [%{do_line: 5, end_line: 8}, %{do_line: 10, end_line: 13}] =
               MigrationParser.table_blocks(source)
    end
  end

  describe "MigrationRewriter.rewrite/1" do
    test "reorders a create table block with fixed-width before varlena" do
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

      assert idx(lines, "add :id_num") < idx(lines, "add :tiny")
      assert idx(lines, "add :email") < idx(lines, "# group A")

      blank_input = """
      create table(:messages) do
        add(:sent_to, :string)

        timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false, null: false)
      end
      """

      assert MigrationRewriter.rewrite(blank_input) == blank_input
    end

    test "can ignore blank lines as barriers and remove them" do
      input = """
      create table(:messages) do
        add(:sent_to, :string)

        timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false, null: false)
      end
      """

      out = MigrationRewriter.rewrite(input, blank_lines: :ignore)
      lines = String.split(out, "\n")

      assert idx(lines, "timestamps") < idx(lines, "add(:sent_to")
      refute "" in Enum.drop(lines, -1)
    end

    test "moves timestamps before variable-length columns" do
      input = """
      create table(:users) do
        add :email, :citext, null: false
        add :login, :citext, null: false
        timestamps(type: :utc_datetime_usec, inserted_at: :created_at, null: false)
      end
      """

      out = MigrationRewriter.rewrite(input)
      lines = String.split(out, "\n")

      assert idx(lines, "timestamps") < idx(lines, "add :email")
      assert idx(lines, "timestamps") < idx(lines, "add :login")
    end

    test "handles alter table, create_if_not_exists, timestamps, and multi-line column calls" do
      input = """
      alter table(:users) do
        add :flag,
            :boolean,
            null: false
        add :big_id, :bigint
      end

      create_if_not_exists table(:events) do
        add :payload, :text
        timestamps(
          type: :utc_datetime_usec
        )
        add :at, :utc_datetime
      end
      """

      out = MigrationRewriter.rewrite(input)
      lines = String.split(out, "\n")

      assert idx(lines, "add :big_id") < idx(lines, "add :flag")
      assert idx(lines, "timestamps") < idx(lines, "add :payload")
      assert idx(lines, "add :at") < idx(lines, "add :payload")
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
      assert PsqlTetris.Formatter.format(src, [file: "lib/foo.exs"] ++ opts_pg) == src

      rewritten =
        PsqlTetris.Formatter.format(
          src,
          [file: "priv/repo/migrations/20260222_create.exs"] ++ opts_pg
        )

      assert rewritten != src
      assert String.contains?(rewritten, "add :b, :bigint\n")
    end

    test "format/2 passes psql_tetris layout options to the rewriter" do
      src = """
      create table(:t) do
        add :body, :text
        add :kind, :custom_status, null: false
      end
      """

      opts = [
        file: "priv/repo/migrations/20260222_create.exs",
        psql_tetris: [enabled: true, unknown_type_layout: {:fixed, 4, 4}]
      ]

      rewritten = PsqlTetris.Formatter.format(src, opts)
      lines = String.split(rewritten, "\n")

      assert idx(lines, "add :kind") < idx(lines, "add :body")
    end

    test "format/2 is a no-op when Postgrex is not loaded unless explicitly enabled" do
      src = """
      create table(:t) do
        add :a, :boolean
        add :b, :bigint
      end
      """

      refute Code.ensure_loaded?(Postgrex)

      assert PsqlTetris.Formatter.format(src,
               file: "priv/repo/migrations/20260222_create.exs"
             ) == src
    end

    test "migration_file?/2 honours custom paths" do
      opts = [psql_tetris: [migration_paths: ["db/migrate/"]]]
      assert PsqlTetris.Formatter.migration_file?("apps/x/db/migrate/001.exs", opts)
      refute PsqlTetris.Formatter.migration_file?("priv/repo/migrations/001.exs", opts)
    end
  end

  defp idx(lines, substr), do: Enum.find_index(lines, &String.contains?(&1, substr))

  defp add_names(lines) do
    Enum.map(lines, fn line ->
      [_, name] = Regex.run(~r/add :([a-z_]+)/, line)
      String.to_atom(name)
    end)
  end
end
