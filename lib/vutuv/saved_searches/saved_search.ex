defmodule Vutuv.SavedSearches.SavedSearch do
  @moduledoc """
  A member's stored search with an optional e-mail alert (issue #935).

  `kind` picks the side of the market — `:jobs` replays the `/jobs` board,
  `:people` replays the `/search` people query. `query` is the page's raw URL
  query string, so saving is just capturing the current filters and the sweeper
  re-runs the exact same query. `notify` is the cadence (defaults to `:none`, so
  saving a search never silently subscribes anyone to mail); `last_notified_at`
  is the high-water mark the sweeper advances so a mail never repeats a result.
  """
  use VutuvWeb, :model

  @kinds ~w(jobs people)a
  @cadences ~w(none daily weekly)a

  schema "saved_searches" do
    field(:kind, Ecto.Enum, values: @kinds)
    field(:query, :string)
    field(:notify, Ecto.Enum, values: @cadences, default: :none)
    field(:last_run_at, :naive_datetime)
    field(:last_notified_at, :naive_datetime)

    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  @doc "The two sides of the market a search can cover."
  def kinds, do: @kinds

  @doc "The alert cadences the save/edit forms offer."
  def cadences, do: @cadences

  @doc """
  Casts a new saved search. `kind` and `query` are required; `notify` defaults
  to `:none`. The `query` column is varchar(255) (a board/search URL never runs
  long), so cap it to avoid a Postgres 22001 on save.
  """
  def changeset(saved_search, attrs) do
    saved_search
    |> cast(attrs, [:kind, :query, :notify])
    |> validate_required([:kind, :query])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:notify, @cadences)
    |> update_change(:query, &String.trim/1)
    |> validate_length(:query, min: 1, max: 255)
  end

  @doc "Casts only the alert cadence (the settings edit row)."
  def notify_changeset(saved_search, attrs) do
    saved_search
    |> cast(attrs, [:notify])
    |> validate_required([:notify])
    |> validate_inclusion(:notify, @cadences)
  end
end
