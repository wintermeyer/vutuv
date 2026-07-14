defmodule Vutuv.Tags.UserTagEndorsement do
  @moduledoc false

  use VutuvWeb, :model

  schema "user_tag_endorsements" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:user_tag, Vutuv.Tags.UserTag)

    timestamps()
  end

  @doc """
  Builds a changeset based on the `struct` and `params`.
  """
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:user_id, :user_tag_id])
    |> unique_constraint(:user_id_user_tag_id)
  end

  @doc """
  Endorsements whose endorser is currently publicly visible: activated and
  not frozen / suspended / deactivated. The same gate the follower,
  connection, tag-member and most-followed counts use, so a hidden or
  never-activated endorser no longer inflates a public endorsement count.

  Preload through this (`preload(endorsements: ^UserTagEndorsement.visible())`)
  wherever an in-memory `length/1`/`Enum.count/1` over the loaded rows feeds a
  displayed count or a rendered endorser list, matching the SQL aggregate in
  `Vutuv.Tags.UserTag.ordered_by_endorsements/0`.
  """
  def visible(query \\ __MODULE__) do
    import Vutuv.Moderation.Query, only: [account_hidden: 1, account_confirmed_row: 1]

    from(e in query,
      join: u in assoc(e, :user),
      where: account_confirmed_row(u) and not account_hidden(u.id)
    )
  end

  @doc """
  Like `visible/0`, but also preloads the endorser `:user` (reusing the same
  visibility join), so a caller can render the endorsers' avatars — the social
  proof on the profile Tags card — without an extra query per endorsement.
  """
  def visible_with_endorser(query \\ __MODULE__) do
    from([e, u] in visible(query), preload: [user: u])
  end
end
