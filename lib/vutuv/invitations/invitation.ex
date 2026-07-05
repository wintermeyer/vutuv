defmodule Vutuv.Invitations.Invitation do
  @moduledoc """
  A record that a given email address has been invited to join this vutuv.

  Stores only a hash of the normalized address (never the plaintext), the
  inviter, the invitation's language and whether the inviter wants to
  auto-follow the person once they register. `visited_at` is stamped the first
  time the invited person opens the prefilled sign-up link. The unique index on
  `email_hash` enforces the "invite each address at most once, site-wide" rule.
  """
  use VutuvWeb, :model

  alias Vutuv.Accounts.User

  schema "invitations" do
    field(:email_hash, :string)
    field(:locale, :string)
    field(:auto_follow, :boolean, default: false)
    field(:visited_at, :naive_datetime)

    belongs_to(:user, User)

    timestamps()
  end

  @doc """
  Builds an invitation for insert. `user_id` is set on the struct by the
  context (never cast), so a request can't forge who the inviter is. A repeat
  address fails the `email_hash` unique constraint, which the context turns into
  an "already invited" outcome.
  """
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email_hash, :locale, :auto_follow])
    |> validate_required([:email_hash, :locale])
    |> unique_constraint(:email_hash)
  end
end
