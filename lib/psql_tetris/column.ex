defmodule PsqlTetris.Column do
  @moduledoc """
  Source-preserving representation of one Ecto migration `add` statement.

  The column is the unified source of truth for ordering facts: it carries the
  parsed migration data, the resolved PostgreSQL layout, and exposes
  `sort_key/1` for callers that need stable ordering.
  """

  alias PsqlTetris.Layout

  @type t :: %__MODULE__{
          name: term(),
          migration_type: term(),
          layout: Layout.t(),
          primary_key?: boolean(),
          reference?: boolean(),
          nullable?: boolean(),
          source_lines: [String.t()]
        }

  defstruct [
    :name,
    :migration_type,
    :layout,
    primary_key?: false,
    reference?: false,
    nullable?: true,
    source_lines: []
  ]

  @doc "Returns the physical/semantic ordering key for this column."
  @spec sort_key(t()) :: tuple()
  def sort_key(%__MODULE__{primary_key?: true}), do: {0, 0, 0, 0, 0}

  def sort_key(%__MODULE__{
        layout: %Layout{kind: :fixed, align_bytes: 1, width: width},
        reference?: true,
        nullable?: nullable?
      })
      when rem(width, 8) == 0 do
    {1, 1, 0, -width, nullable?}
  end

  def sort_key(%__MODULE__{
        layout: %Layout{kind: :fixed, align_bytes: align_bytes, width: width},
        reference?: reference?,
        nullable?: nullable?
      }) do
    {1, 8 - align_bytes, reference?, -width, nullable?}
  end

  def sort_key(%__MODULE__{
        layout: %Layout{kind: :varlena, align_bytes: align_bytes},
        reference?: reference?,
        nullable?: nullable?
      }) do
    {1, 9, reference?, -align_bytes, nullable?}
  end
end
