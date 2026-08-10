defmodule Vutuv.Tags.TagDistinction do
  @moduledoc """
  Two tags a human has looked at and called different topics (issue #1338).

  `Ruby` and `Ruby on Rails` share a word, an assisted pass will keep noticing
  that, and a reviewer should have to say so only once. The pair is stored with
  the smaller id first, so the fact is one row whichever way round it is named,
  and the unique index is what makes saying it twice harmless.

  It refuses a merge as well as a proposal: a rejected pair is not merely
  unproposed, it is a decision.
  """

  use VutuvWeb, :model

  alias Vutuv.Accounts.User
  alias Vutuv.Tags.Tag

  schema "tag_distinctions" do
    belongs_to(:tag_a, Tag)
    belongs_to(:tag_b, Tag)
    belongs_to(:admin_user, User)

    timestamps()
  end

  def changeset(tag_distinction, attrs) do
    tag_distinction
    |> cast(attrs, [:tag_a_id, :tag_b_id, :admin_user_id])
    |> validate_required([:tag_a_id, :tag_b_id])
    |> unique_constraint([:tag_a_id, :tag_b_id])
  end

  @doc """
  The two ids in their stored order (smaller first), so a lookup and a write
  agree about which is which.
  """
  def ordered(%Tag{id: a}, %Tag{id: b}), do: ordered(a, b)
  def ordered(a, b) when a <= b, do: {a, b}
  def ordered(a, b), do: {b, a}
end
