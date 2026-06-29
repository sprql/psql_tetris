defmodule PsqlTetris.MigrationRewriter do
  @moduledoc """
  Source-preserving rewriter for Ecto migration table blocks.

  Table blocks are discovered from Elixir AST metadata, so multiline table
  headers and variants such as `create_if_not_exists table(...) do` are handled
  structurally. Inside each discovered body, only contiguous runs of
  column-defining calls (`add/2,3` and `timestamps/0,1`) are reordered;
  comments, `modify/3`, `remove/2`, indexes, and any other statements remain
  barriers. Blank lines are barriers by default, but can be configured to be
  ignored and removed with `blank_lines: :ignore`.
  """

  alias PsqlTetris.Column
  alias PsqlTetris.Layout
  alias PsqlTetris.LayoutSimulation
  alias PsqlTetris.MigrationParser

  @column_start ~r/^\s*(?:add|timestamps)[\s(]/
  @skip_marker ~r/^\s*#\s*psql_tetris:\s*skip\b/

  @spec rewrite(String.t(), keyword()) :: String.t()
  def rewrite(source, opts \\ []) when is_binary(source) do
    trailing_newline? = String.ends_with?(source, "\n")
    lines = String.split(source, "\n")

    result_lines =
      source
      |> MigrationParser.table_blocks()
      |> Enum.reverse()
      |> Enum.reduce(lines, fn block, acc -> rewrite_block(block, acc, opts) end)

    result = Enum.join(result_lines, "\n")

    cond do
      trailing_newline? and not String.ends_with?(result, "\n") ->
        result <> "\n"

      not trailing_newline? and String.ends_with?(result, "\n") ->
        String.trim_trailing(result, "\n")

      true ->
        result
    end
  end

  defp rewrite_block(%{do_line: do_line, end_line: end_line}, lines, opts) do
    body_start = do_line + 1
    body_end = end_line - 1

    if body_start > body_end do
      lines
    else
      prefix = Enum.take(lines, body_start - 1)
      body = lines |> Enum.slice((body_start - 1)..(body_end - 1)//1)
      suffix = Enum.drop(lines, body_end)

      prefix ++ reorder_body(body, opts) ++ suffix
    end
  end

  @doc false
  def reorder_body(lines, opts \\ []) do
    if Enum.any?(lines, &Regex.match?(@skip_marker, &1)) do
      lines
    else
      lines
      |> group(:gap, [], [], opts)
      |> Enum.reverse()
      |> chunk_by_kind(opts)
      |> Enum.flat_map(fn
        {:add, runs} -> runs |> sort_run() |> Enum.flat_map(& &1.source_lines)
        {:add_with_blanks, runs} -> sort_run_ignoring_blanks(runs)
        {:other, runs} -> Enum.flat_map(runs, & &1.lines)
      end)
    end
  end

  @doc false
  def simulate_body(lines, opts \\ []) do
    lines
    |> columns_from_body(opts)
    |> LayoutSimulation.compare_current_to_sorted(opts)
  end

  @doc false
  def columns_from_body(lines, opts \\ []) do
    lines
    |> group(:gap, [], [], opts)
    |> Enum.reverse()
    |> Enum.filter(&(&1.kind == :add))
    |> Enum.map(& &1.column)
  end

  defp group([], :gap, buf, items, opts), do: finalize_gap(buf, items, opts)

  defp group([], :in_add, buf, items, opts) do
    finalize_gap(buf, items, opts)
  end

  defp group([line | rest], :gap, buf, items, opts) do
    if Regex.match?(@column_start, line) do
      items_with_gap = finalize_gap(buf, items, opts)

      if parses?([line]) do
        group(rest, :gap, [], [build_add([line], opts) | items_with_gap], opts)
      else
        group(rest, :in_add, [line], items_with_gap, opts)
      end
    else
      group(rest, :gap, [line | buf], items, opts)
    end
  end

  defp group([line | rest], :in_add, buf, items, opts) do
    new_buf = [line | buf]
    ordered = Enum.reverse(new_buf)

    if parses?(ordered) do
      group(rest, :gap, [], [build_add(ordered, opts) | items], opts)
    else
      group(rest, :in_add, new_buf, items, opts)
    end
  end

  defp finalize_gap([], items, _opts), do: items

  defp finalize_gap(buf, items, opts) do
    lines = Enum.reverse(buf)

    if blank_separator?(lines, opts) do
      [build_blank(lines) | items]
    else
      [build_other(lines) | items]
    end
  end

  defp build_other(lines), do: %{kind: :other, lines: lines}
  defp build_blank(lines), do: %{kind: :blank, lines: lines}

  defp blank_separator?(lines, opts) do
    not blank_lines_barrier?(opts) and Enum.all?(lines, &(String.trim(&1) == ""))
  end

  defp blank_lines_barrier?(opts) do
    case Keyword.get(opts, :blank_lines, :barrier) do
      :ignore -> false
      :soft -> false
      false -> false
      _ -> true
    end
  end

  defp build_add(lines, opts) do
    text = Enum.join(lines, "\n")

    column =
      case Code.string_to_quoted(String.trim(text)) do
        {:ok, ast} -> column_from_ast(ast, lines, opts)
        _ -> column_from_add_info(%{name: nil, type: :unknown, opts: []}, lines, opts)
      end

    %{kind: :add, column: column}
  end

  defp column_from_ast({:timestamps, _meta, args}, lines, opts) when is_list(args) do
    timestamp_opts =
      case args do
        [] -> []
        [kw] when is_list(kw) -> normalize_opts(kw)
        _ -> []
      end

    type = Keyword.get(timestamp_opts, :type, :naive_datetime)

    %Column{
      name: :__timestamps__,
      migration_type: type,
      layout: Layout.resolve(type, timestamp_opts, opts),
      primary_key?: false,
      reference?: false,
      nullable?: Keyword.get(timestamp_opts, :null, false),
      source_lines: lines
    }
  end

  defp column_from_ast(ast, lines, opts) do
    column_from_add_info(add_info(ast), lines, opts)
  end

  defp add_info({:add, _meta, args}) when is_list(args) and length(args) >= 2 do
    [name, type | rest] = args

    opts =
      case rest do
        [kw] when is_list(kw) -> normalize_opts(kw)
        _ -> []
      end

    %{name: name, type: simplify_type(type), opts: opts}
  end

  defp add_info(_), do: %{name: nil, type: :unknown, opts: []}

  defp column_from_add_info(%{name: name, type: type, opts: add_opts}, lines, opts) do
    %Column{
      name: name,
      migration_type: type,
      layout: Layout.resolve(type, add_opts, opts),
      primary_key?: Keyword.get(add_opts, :primary_key) == true,
      reference?: reference_type?(type),
      nullable?: Keyword.get(add_opts, :null) != false,
      source_lines: lines
    }
  end

  defp simplify_type({:references, _meta, args}) when is_list(args) do
    opts =
      case args do
        [_target] -> []
        [_target, kw] when is_list(kw) -> normalize_opts(kw)
        _ -> []
      end

    {:references, opts}
  end

  defp simplify_type({:array, _meta, [inner]}), do: {:array, simplify_type(inner)}
  defp simplify_type(atom) when is_atom(atom), do: atom
  defp simplify_type({tag, _, ctx}) when is_atom(tag) and is_atom(ctx), do: tag
  defp simplify_type({:__block__, _, [v]}), do: simplify_type(v)
  defp simplify_type(other), do: other

  defp reference_type?({:references, opts}) when is_list(opts), do: true
  defp reference_type?(_type), do: false

  defp normalize_opts(kw) do
    Enum.map(kw, fn
      {k, v} when is_atom(k) -> {k, v}
      other -> other
    end)
  end

  defp parses?(lines) do
    case Code.string_to_quoted(Enum.join(lines, "\n")) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp chunk_by_kind(items, opts) do
    items
    |> Enum.chunk_by(&chunk_kind(&1, opts))
    |> Enum.map(fn run -> {chunk_kind(hd(run), opts), run} end)
  end

  defp chunk_kind(%{kind: :blank}, opts) do
    if blank_lines_barrier?(opts), do: :other, else: :add_with_blanks
  end

  defp chunk_kind(%{kind: :add}, opts) do
    if blank_lines_barrier?(opts), do: :add, else: :add_with_blanks
  end

  defp chunk_kind(_item, _opts), do: :other

  defp sort_run(adds) do
    adds
    |> Enum.map(& &1.column)
    |> sort_columns()
  end

  defp sort_run_ignoring_blanks(items) do
    items
    |> Enum.filter(&(&1.kind == :add))
    |> Enum.map(& &1.column)
    |> sort_columns()
    |> Enum.flat_map(& &1.source_lines)
  end

  defp sort_columns(columns) do
    columns
    |> Enum.with_index()
    |> Enum.sort_by(fn {column, index} -> {Column.sort_key(column), index} end)
    |> Enum.map(fn {column, _index} -> column end)
  end
end
