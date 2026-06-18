defmodule Vutuv.Tags.UserTag do
  @moduledoc false

  use VutuvWeb, :model

  schema "user_tags" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:tag, Vutuv.Tags.Tag)

    has_many(:endorsements, Vutuv.Tags.UserTagEndorsement)

    # Filled by ordered_by_endorsements/0 via select_merge, so counting does
    # not require loading the endorsement rows.
    field(:endorsement_count, :integer, virtual: true)

    timestamps()
  end

  @doc """
  Builds a changeset based on the `struct` and `params`.
  """
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:user_id, :tag_id])
    |> unique_constraint(:user_id_tag_id, message: "You already have this tag.")
  end

  @doc """
  A user's tags ordered most endorsed first, ties alphabetically — the
  display order of the profile page and its agent documents (both preload
  through this query; compose with `Ecto.Query.limit/2` for the page's
  cut). The ordering count rides along as the virtual `endorsement_count`;
  callers that need the endorsement *rows* (the profile page's upvote
  state) add `preload(:endorsements)` themselves.
  """
  def ordered_by_endorsements(query \\ __MODULE__) do
    import Vutuv.Moderation.Query, only: [account_hidden: 1, account_confirmed_row: 1]

    from(u in query,
      left_join: e in assoc(u, :endorsements),
      # Count only endorsers who are currently publicly visible (the project-wide
      # rule, shared with the follower / connection / tag-member / most-followed
      # counts). The visibility test rides in the left-join ON clause, so a
      # hidden endorser leaves `endorser` NULL and drops out of count(endorser.id)
      # without discarding the user_tag row (it still shows 0).
      left_join: endorser in assoc(e, :user),
      on:
        account_confirmed_row(endorser) and
          not account_hidden(endorser.id),
      left_join: t in assoc(u, :tag),
      order_by: [desc: count(endorser.id), asc: t.slug],
      # Postgres requires every ordered, non-aggregated column in GROUP BY;
      # each user_tag has exactly one tag, so this keeps one row per user_tag.
      group_by: [u.id, t.slug],
      select_merge: %{endorsement_count: count(endorser.id)},
      preload: [:tag]
    )
  end

  def name(user_tag) do
    tag(user_tag).name
  end

  def truncated_name(user_tag) do
    tag_name = name(user_tag)

    truncated_tag_name =
      tag_name
      |> String.slice(0..50)

    if truncated_tag_name == tag_name do
      tag_name
    else
      truncated_tag_name <> " ..."
    end
  end

  # Read the already-loaded :tag association when present; only hit the database
  # when it has not been preloaded. Callers that render many chips (the profile
  # page, the user_tag index) preload [user_tags: :tag], so this avoids a query
  # per chip while still working on bare structs.
  @doc false
  def tag(%__MODULE__{tag: %Vutuv.Tags.Tag{} = tag}), do: tag
  def tag(%__MODULE__{} = user_tag), do: Vutuv.Repo.preload(user_tag, :tag).tag

  defimpl Phoenix.Param, for: Vutuv.Tags.UserTag do
    alias Vutuv.Tags.UserTag

    def to_param(user_tag) do
      UserTag.tag(user_tag).slug
    end
  end
end
