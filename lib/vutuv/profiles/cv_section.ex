defmodule Vutuv.Profiles.CvSection do
  @moduledoc """
  The two orderings the CV sections (`Vutuv.Profiles.WorkExperience` and
  `Vutuv.Profiles.Education`) share verbatim: grouping an already-ordered list
  into its category buckets, and the newest-first DESC date ordering a CV reads
  by. Both schemas delegate here so the grouping and the sort live in one place
  and the two sections can never disagree; each keeps its own `@kinds`.
  """

  import Ecto.Query
  import Ecto.Changeset, only: [get_change: 2, get_field: 2, put_change: 3]

  @doc """
  Splits an already-ordered `entries` list into `{kind, entries}` pairs in
  `kinds` order, dropping empty categories and keeping the given order within
  each. Shared by both CV schemas' `group_by_kind/1`.
  """
  def group_by_kind(entries, kinds) do
    groups = Enum.group_by(entries, & &1.kind)

    for kind <- kinds, entries = groups[kind], do: {kind, entries}
  end

  @doc """
  Orders a CV-section query newest first, the way a CV reads: ongoing entries
  (no end date) lead — plain `DESC` puts NULLs first in Postgres — then by end
  date, then by start date. Shared by both CV schemas' `order_by_date/1`.
  """
  def order_by_date(query) do
    order_by(query, [x],
      desc: x.end_year,
      desc: x.end_month,
      desc: x.start_year,
      desc: x.start_month
    )
  end

  @doc """
  Builds the `slug` from `fields` (via each schema's `String.Chars`) when any of
  them changed, unique per owner. `module` is the CV-section schema and `fields`
  its slug source columns. Shared by both sections' slug step.
  """
  def put_slug(changeset, module, fields) do
    if Enum.any?(fields, &get_change(changeset, &1)) do
      model = struct(module, Map.new(fields, &{&1, get_field(changeset, &1)}))
      put_change(changeset, :slug, Vutuv.SlugHelpers.gen_slug_unique(model, :slug))
    else
      changeset
    end
  end
end
