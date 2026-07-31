defmodule Vutuv.Repo.Migrations.DeleteUnconfirmedLegacyRegistrations do
  use Ecto.Migration

  alias Vutuv.Accounts

  # Clears the backlog of accounts that registered but never confirmed. They are
  # the bulk of the users table and none of them is a member: no session was ever
  # opened, no post written, nothing logged in the account activity feed. Sign-up
  # wrote an account, an email, a handle and sometimes a few tags, and then the
  # address went unconfirmed and nobody came back.
  #
  # The periodic sweep (Accounts.UnconfirmedRegistrationSweeper) cannot reach
  # them. It only reaps an account whose first "login" PIN was minted alongside
  # it, which is what tells an abandoned sign-up apart from an established member
  # who merely failed a login. PINs expire and are cleared, so every account in
  # this backlog has none left and the sweep passes over it forever. That is why
  # a one-time cleanup is needed, and why it must bring its own guard rather than
  # simply widening the sweep's.
  #
  # The guard is in Accounts.delete_unconfirmed_legacy_registrations/1, where it
  # is unit-tested against real rows: only `email_confirmed? == false` matches
  # (a confirmed member is out, and so is a legacy member whose flag is NULL,
  # since `NULL = false` is not a match), the protected member count is compared
  # before and after and must be identical, and any evidence that a candidate
  # actually used the site stops the whole thing instead of deleting on a wrong
  # assumption. Accounts younger than a week are left to the periodic sweep, so
  # a registration in progress during the deploy is never caught.
  #
  # Deletion goes through Accounts.delete_user/1, the single chokepoint, so the
  # on-disk avatar files these accounts uploaded are removed too. That has one
  # consequence worth naming: delete_user/1 removes files right after its
  # Repo.delete rather than after the surrounding transaction commits, so if a
  # guard were to fire *late* the rolled-back accounts would already have lost
  # their avatars. Every guard that can be checked up front therefore runs before
  # the first delete; only the member-count comparison is necessarily after it.
  #
  # Data-only (no DDL) and N-1 compatible: the currently deployed release keeps
  # reading the users table and simply finds fewer rows, none of which it was
  # serving to anyone.
  def up do
    {deleted, protected} = Accounts.delete_unconfirmed_legacy_registrations()

    IO.puts("deleted #{deleted} unconfirmed registration(s); #{protected} members untouched")
  end

  # The accounts and everything that belonged to them are gone, including files
  # on disk; there is nothing left to reconstruct them from.
  def down, do: :ok
end
