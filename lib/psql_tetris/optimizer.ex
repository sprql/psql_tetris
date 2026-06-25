defmodule PsqlTetris.Optimizer do
  @moduledoc """
  Pure ordering logic. Given a list of column descriptors, returns them in the order PostgreSQL would prefer for minimal row padding.

  A column descriptor is a map (or struct-shaped map) with at least:

    * `:type` : the Ecto migration type (atom or tuple)
    * `:opts` : keyword list passed to `add/3` (may be `[]`)

  Any other keys are preserved untouched.

  Explicit primary key columns come first for readability, matching Ecto's implicit primary key convention. After that, the sort is stable, so columns of the same alignment rank keep their author-defined order. Within a rank, `null: false` columns come first, which is a tiny CPU win during tuple deforming.
  """

  alias PsqlTetris.Types

  @spec optimize([map()]) :: [map()]
  def optimize(columns) when is_list(columns) do
    columns
    |> Enum.with_index()
    |> Enum.sort_by(fn {col, idx} ->
      if primary_key?(col) do
        {0, idx}
      else
        rank = Types.rank(col.type, Map.get(col, :opts, []))
        not_null_first = if not_null?(col), do: 0, else: 1
        {1, rank, not_null_first, idx}
      end
    end)
    |> Enum.map(fn {col, _idx} -> col end)
  end

  defp primary_key?(%{opts: opts}) when is_list(opts), do: Keyword.get(opts, :primary_key) == true
  defp primary_key?(_), do: false

  defp not_null?(%{opts: opts}) when is_list(opts), do: Keyword.get(opts, :null) == false
  defp not_null?(_), do: false
end
