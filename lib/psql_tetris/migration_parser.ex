defmodule PsqlTetris.MigrationParser do
  @moduledoc """
  AST discovery for Ecto migration table blocks.

  This module identifies `create table`, `create_if_not_exists table`, `alter
  table`, and `alter_if_exists table` blocks without relying on line-oriented
  regular expressions. Rewriting remains source-preserving and happens in
  `PsqlTetris.MigrationRewriter`.
  """

  @table_ops [:create, :create_if_not_exists, :alter, :alter_if_exists]

  @type table_block :: %{do_line: pos_integer(), end_line: pos_integer()}

  @doc "Returns table-block source ranges discovered from Elixir AST metadata."
  @spec table_blocks(String.t()) :: [table_block()]
  def table_blocks(source) when is_binary(source) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true) do
      {:ok, ast} ->
        ast
        |> collect_blocks()
        |> Enum.uniq()
        |> Enum.sort_by(& &1.do_line)

      {:error, _} ->
        []
    end
  end

  defp collect_blocks(ast) do
    {_ast, blocks} =
      Macro.prewalk(ast, [], fn
        {op, meta, [table_ast, [do: _body]]} = node, acc when op in @table_ops ->
          if table_call?(table_ast) do
            block = %{do_line: meta[:do][:line], end_line: meta[:end][:line]}
            {node, [block | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(blocks)
  end

  defp table_call?({:table, _meta, args}) when is_list(args), do: true
  defp table_call?(_), do: false
end
