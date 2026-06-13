defmodule Vutuv.Posts.PostDenial do
  @moduledoc """
  One audience exclusion of a post (deny-model visibility).

  A post with no denials is public. Each denial excludes the readers matching
  exactly one target — a single user or a wildcard — and a reader matching
  *any* denial is excluded (union semantics). The author always sees their own
  posts; that invariant lives in `Vutuv.Posts`, not in data.

  Wildcards:

    * `"everyone"` — only the author (the global author invariant makes
      "everyone but me" out of plain "everyone")
    * `"non_connections"` — only the author's accepted connections
    * `"non_followers"` — only people who follow the author
    * `"non_followees"` — only people the author follows
    * `"logged_out"` — only logged-in members

  Any denial at all also closes anonymous access (a logged-out visitor cannot
  be proven not-denied) — enforced by the resolver, mirrored in the UI copy.
  """

  use VutuvWeb, :model

  @wildcards ~w(everyone non_connections non_followers non_followees logged_out)

  # The post_denials.group_id column is intentionally still present (audience
  # Groups were removed; the table-drop is a sequenced follow-up deploy), but
  # the schema no longer maps it: a denial now targets a single user or a
  # wildcard. The DB check constraint still holds (group_id stays NULL).
  schema "post_denials" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:denied_user, Vutuv.Accounts.User)
    field(:wildcard, :string)

    timestamps()
  end

  def wildcards, do: @wildcards

  def changeset(denial, params \\ %{}) do
    denial
    |> cast(params, [:denied_user_id, :wildcard])
    |> validate_inclusion(:wildcard, @wildcards)
    |> validate_exactly_one_target()
    |> check_constraint(:wildcard, name: :exactly_one_target)
  end

  defp validate_exactly_one_target(changeset) do
    targets = [
      get_field(changeset, :denied_user_id),
      get_field(changeset, :wildcard)
    ]

    case Enum.count(targets, &(not is_nil(&1))) do
      1 -> changeset
      _ -> add_error(changeset, :wildcard, "exactly one of user or wildcard must be set")
    end
  end
end
