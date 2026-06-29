defmodule PsqlTetris.LayoutSimulation do
  @moduledoc """
  Simulates PostgreSQL tuple data layout for an ordered set of migration columns.

  The simulation is intentionally offline and assumption-driven. Fixed-width
  columns use static widths from `PsqlTetris.Layout`; varlena columns use
  a configurable assumed inline width so callers can compare column orders under
  a concrete storage model. The result also includes a simple hot-path score:
  weighted column access by ordinal and byte offset, where lower is better.
  """

  alias PsqlTetris.Column
  alias PsqlTetris.Layout

  defmodule Comparison do
    @moduledoc """
    Side-by-side layout simulations for an original and candidate column order.
    """

    alias PsqlTetris.LayoutSimulation

    @enforce_keys [:current, :sorted, :simulated_best]
    defstruct [:current, :sorted, :simulated_best]

    @type t :: %__MODULE__{
            current: LayoutSimulation.t(),
            sorted: LayoutSimulation.t(),
            simulated_best: LayoutSimulation.t()
          }
  end

  defmodule PlacedColumn do
    @moduledoc """
    One column placed in a simulated PostgreSQL tuple data area.
    """

    @enforce_keys [:column, :ordinal, :offset, :padding_before, :width, :align_bytes]
    defstruct [:column, :ordinal, :offset, :padding_before, :width, :align_bytes]

    @type t :: %__MODULE__{
            column: Column.t(),
            ordinal: non_neg_integer(),
            offset: non_neg_integer(),
            padding_before: non_neg_integer(),
            width: non_neg_integer(),
            align_bytes: Layout.align_bytes()
          }
  end

  @enforce_keys [:columns, :placed_columns, :data_width, :padding_width, :hot_path_score]
  defstruct [:columns, :placed_columns, :data_width, :padding_width, :hot_path_score]

  @type access_weights :: %{term() => number()}

  @type t :: %__MODULE__{
          columns: [Column.t()],
          placed_columns: [PlacedColumn.t()],
          data_width: non_neg_integer(),
          padding_width: non_neg_integer(),
          hot_path_score: number()
        }

  @doc """
  Simulates tuple data layout for columns in their current order.

  Options:

    * `:varlena_width` - assumed inline width for varlena columns. Defaults to 8.
    * `:access_weights` - map of column name to access weight for hot-path score.
      Higher weight means the column is assumed to be accessed more often.
  """
  @spec simulate([Column.t()], keyword()) :: t()
  def simulate(columns, opts \\ []) when is_list(columns) do
    {placed_columns, final_offset, padding_width} =
      columns
      |> Stream.with_index()
      |> Enum.reduce({[], 0, 0}, fn {column, ordinal}, {placed, offset, padding} ->
        width = assumed_width(column.layout, opts)
        align_bytes = column.layout.align_bytes
        padding_before = alignment_padding(offset, align_bytes)
        placed_offset = offset + padding_before

        placed_column = %PlacedColumn{
          column: column,
          ordinal: ordinal,
          offset: placed_offset,
          padding_before: padding_before,
          width: width,
          align_bytes: align_bytes
        }

        {[placed_column | placed], placed_offset + width, padding + padding_before}
      end)

    placed_columns = Enum.reverse(placed_columns)

    %__MODULE__{
      columns: columns,
      placed_columns: placed_columns,
      data_width: final_offset,
      padding_width: padding_width,
      hot_path_score: hot_path_score(placed_columns, opts)
    }
  end

  @doc """
  Simulates the given order, the current `PsqlTetris.Column.sort_key/1` order,
  and the best order found by exhaustive simulation when the column count is
  small enough.
  """
  @spec compare_current_to_sorted([Column.t()], keyword()) :: Comparison.t()
  def compare_current_to_sorted(columns, opts \\ []) when is_list(columns) do
    sorted_columns = sort_columns(columns)

    %Comparison{
      current: simulate(columns, opts),
      sorted: simulate(sorted_columns, opts),
      simulated_best: simulate_best(columns, opts)
    }
  end

  @doc """
  Returns the lowest-scoring simulated layout found for the columns.

  The search is exhaustive up to `:max_exhaustive_columns` columns, defaulting to
  8. Larger inputs fall back to the existing `PsqlTetris.Column.sort_key/1`
  heuristic so simulation remains safe in formatter workflows.
  """
  @spec simulate_best([Column.t()], keyword()) :: t()
  def simulate_best(columns, opts \\ []) when is_list(columns) do
    max_exhaustive_columns = Keyword.get(opts, :max_exhaustive_columns, 8)

    if length(columns) <= max_exhaustive_columns do
      columns
      |> permutations()
      |> Enum.map(&simulate(&1, opts))
      |> Enum.min_by(&simulation_score/1)
    else
      columns
      |> sort_columns()
      |> simulate(opts)
    end
  end

  defp sort_columns(columns) do
    columns
    |> Enum.with_index()
    |> Enum.sort_by(fn {column, index} -> {Column.sort_key(column), index} end)
    |> Enum.map(fn {column, _index} -> column end)
  end

  defp simulation_score(%__MODULE__{} = simulation) do
    {simulation.padding_width, simulation.data_width, simulation.hot_path_score}
  end

  defp permutations([]), do: [[]]

  defp permutations(columns) do
    for column <- columns,
        rest <- permutations(List.delete(columns, column)) do
      [column | rest]
    end
  end

  defp assumed_width(%Layout{kind: :fixed, width: width}, _opts), do: width

  defp assumed_width(%Layout{kind: :varlena}, opts) do
    Keyword.get(opts, :varlena_width, 8)
  end

  defp alignment_padding(offset, align_bytes) do
    remainder = rem(offset, align_bytes)

    if remainder == 0 do
      0
    else
      align_bytes - remainder
    end
  end

  defp hot_path_score(placed_columns, opts) do
    access_weights = Keyword.get(opts, :access_weights, %{})

    Enum.reduce(placed_columns, 0, fn %PlacedColumn{} = placed_column, score ->
      weight = Map.get(access_weights, placed_column.column.name, 0)
      score + weight * (placed_column.ordinal + placed_column.offset)
    end)
  end
end
