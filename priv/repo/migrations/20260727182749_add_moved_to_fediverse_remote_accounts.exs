defmodule Vutuv.Repo.Migrations.AddMovedToFediverseRemoteAccounts do
  use Ecto.Migration

  @moduledoc """
  An account somebody here follows moved to another server (issue #1168).

  The mirror of `users.moved_to`, which records one of **our** members moving
  out (issue #986). `moved_to` is the successor's actor URI, taken from a
  verified inbound `Move`: verified meaning the successor's own actor document
  names the old URI in its `alsoKnownAs`, which is exactly the check every other
  server performs on us before it re-points its followers.

  `text` like every other remote URI here, capped in the changeset. Nullable and
  null for everybody: an account that has not moved has not moved.

  The follow rows keep their own record of the swap (`state: "moved"`), so the
  two halves are separable: the account says where it went, each follow says
  whether it has been re-pointed yet.
  """

  def change do
    alter table(:fediverse_remote_accounts) do
      add(:moved_to, :text)
    end

    # The Accept of a re-follow asks "which accounts moved here?" to finish the
    # swap. Partial, because almost no account has ever moved.
    create(index(:fediverse_remote_accounts, [:moved_to], where: "moved_to IS NOT NULL"))
  end
end
