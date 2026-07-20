defmodule Vutuv.Tags.TagFollow do
  @moduledoc """
  A member's private subscription to a tag (issue #872): `user_id` follows
  `tag_id`. It pulls the tag's posts into the member's `/feed` — the topic-shaped
  twin of `Vutuv.Social.Follow`, but **silent**: a tag has no owner, so following
  it notifies no one and exposes no public follower list (only an aggregate
  count). Anyone may follow any tag, with no approval.

  Every path goes through `Vutuv.Tags` (`follow_tag/2` / `unfollow_tag/2`), which
  always sets `user_id` from the session user — never from request params — so a
  request cannot forge a subscription on someone else's behalf.
  """

  use VutuvWeb, :model

  schema "tag_follows" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:tag, Vutuv.Tags.Tag)

    timestamps()
  end

  @fields ~w(user_id tag_id)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:tag_id,
      name: :tag_follows_user_id_tag_id_index,
      message: "You're already following this tag."
    )
    |> foreign_key_constraint(:tag_id)
    |> foreign_key_constraint(:user_id)
  end
end
