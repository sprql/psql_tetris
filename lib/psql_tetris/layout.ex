defmodule PsqlTetris.Layout do
  @moduledoc """
  Resolves migration column types to PostgreSQL physical storage metadata.

  The struct stores the physical facts needed for column ordering: fixed versus
  variable length and byte alignment. Resolution is deterministic and offline:
  known Ecto migration aliases and PostgreSQL type spellings are handled from a
  static metadata, while unknown/custom types use a configurable fallback layout.
  """

  @type align_bytes :: 8 | 4 | 2 | 1
  @type kind :: :fixed | :varlena

  @type t :: %__MODULE__{
          kind: kind(),
          width: pos_integer() | nil,
          align_bytes: align_bytes()
        }

  defstruct [:kind, :width, :align_bytes]

  @layouts %{
    # Ecto migration aliases.
    :id => {:fixed, 8, 8},
    :binary_id => {:fixed, 16, 1},
    :string => :varlena,
    :binary => :varlena,
    :map => :varlena,
    :decimal => :varlena,
    :citext => :varlena,
    :float => {:fixed, 8, 8},
    :double => {:fixed, 8, 8},
    :time_usec => {:fixed, 8, 8},
    :utc_datetime => {:fixed, 8, 8},
    :utc_datetime_usec => {:fixed, 8, 8},
    :naive_datetime => {:fixed, 8, 8},
    :naive_datetime_usec => {:fixed, 8, 8},

    # Fixed-width PostgreSQL built-ins and common SQL spellings.
    "int8" => {:fixed, 8, 8},
    "bigint" => {:fixed, 8, 8},
    "bigserial" => {:fixed, 8, 8},
    "serial8" => {:fixed, 8, 8},
    "float8" => {:fixed, 8, 8},
    "double precision" => {:fixed, 8, 8},
    "timestamp" => {:fixed, 8, 8},
    "timestamp without time zone" => {:fixed, 8, 8},
    "timestamptz" => {:fixed, 8, 8},
    "timestamp with time zone" => {:fixed, 8, 8},
    "interval" => {:fixed, 16, 8},
    "timetz" => {:fixed, 12, 8},
    "time with time zone" => {:fixed, 12, 8},
    "money" => {:fixed, 8, 8},
    "int4" => {:fixed, 4, 4},
    "integer" => {:fixed, 4, 4},
    "int" => {:fixed, 4, 4},
    "serial" => {:fixed, 4, 4},
    "serial4" => {:fixed, 4, 4},
    "date" => {:fixed, 4, 4},
    "time" => {:fixed, 8, 8},
    "time without time zone" => {:fixed, 8, 8},
    "float4" => {:fixed, 4, 4},
    "real" => {:fixed, 4, 4},
    "oid" => {:fixed, 4, 4},
    "uuid" => {:fixed, 16, 1},
    "int2" => {:fixed, 2, 2},
    "smallint" => {:fixed, 2, 2},
    "smallserial" => {:fixed, 2, 2},
    "serial2" => {:fixed, 2, 2},
    "bool" => {:fixed, 1, 1},
    "boolean" => {:fixed, 1, 1},
    "char" => {:fixed, 1, 1},

    # Common varlena PostgreSQL built-ins and common SQL spellings.
    "text" => :varlena,
    "varchar" => :varlena,
    "character varying" => :varlena,
    "bpchar" => :varlena,
    "character" => :varlena,
    "bytea" => :varlena,
    "json" => :varlena,
    "jsonb" => :varlena,
    "numeric" => :varlena,
    "decimal" => :varlena,
    "xml" => :varlena,
    "citext" => :varlena
  }

  @doc "Resolves an Ecto migration type and add options to layout metadata."
  @spec resolve(term(), keyword(), keyword()) :: t()
  def resolve(type, add_opts, opts \\ [])

  def resolve({:references, inner_opts}, add_opts, opts) when is_list(inner_opts) do
    type = Keyword.get(inner_opts, :type) || Keyword.get(add_opts, :type, :id)
    resolve(type, [], opts)
  end

  def resolve({:array, _inner}, _add_opts, _opts), do: varlena()

  def resolve(type, _add_opts, opts) when is_atom(type) do
    type_name = Atom.to_string(type)

    @layouts
    |> Map.get(type)
    |> case do
      nil -> lookup_pg_type(type_name, opts)
      fact -> layout(fact, opts)
    end
  end

  def resolve(type, _add_opts, opts) when is_binary(type), do: lookup_pg_type(type, opts)
  def resolve(_type, _add_opts, opts), do: unknown_layout(opts)

  defp lookup_pg_type(type, opts) do
    type =
      type
      |> String.downcase()
      |> String.trim()

    if String.ends_with?(type, "[]") do
      varlena()
    else
      type = strip_typmod(type)

      type
      |> lookup_custom_type(opts)
      |> case do
        nil -> Map.get(@layouts, type)
        fact -> fact
      end
      |> layout(opts)
    end
  end

  defp strip_typmod(type), do: String.replace(type, ~r/\s*\(.*$/, "")

  defp lookup_custom_type(type, opts) do
    opts
    |> custom_type_layouts()
    |> Map.get(type)
  end

  defp custom_type_layouts(opts) do
    opts
    |> Keyword.get(:custom_type_layouts, [])
    |> Enum.into(%{}, fn {name, layout} -> {to_string(name), layout} end)
  end

  defp layout(fact, opts)

  defp layout({:fixed, width, align_bytes}, _opts) do
    %__MODULE__{kind: :fixed, width: width, align_bytes: align_bytes}
  end

  defp layout(:varlena, _opts), do: varlena()
  defp layout(nil, opts), do: unknown_layout(opts)

  defp unknown_layout(opts) do
    opts
    |> Keyword.get(:unknown_type_layout, :varlena)
    |> layout([])
  end

  defp varlena, do: %__MODULE__{kind: :varlena, width: nil, align_bytes: 4}
end
