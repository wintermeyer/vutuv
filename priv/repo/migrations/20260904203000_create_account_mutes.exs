defmodule Vutuv.Repo.Migrations.CreateAccountMutes do
  @moduledoc """
  What a reader wants to stop seeing from one account, whether or not they
  follow it. `Vutuv.Mutes` says why this is a table of its own rather than
  another flag on the follow edge: a boosted account is usually one nobody here
  follows, so the flag on `follows.muted` has nowhere to live for it.

  `scope` is how much of that account is silenced — `all` for everything they
  write, `reposts` for what they pass on while their own posts stay. The second
  is why a row can name an account the reader *does* follow.

  New table, so N-1 compatible: the running release neither reads nor writes it.
  """
  use Ecto.Migration

  def change do
    create table(:account_mutes) do
      # The reader. Every row is one member's private view of somebody else, so
      # nothing here is ever read on behalf of another account.
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      # The silenced account, in the three shapes an author can have here: a
      # member, a page (issue #1336), an account on another network. Exactly one
      # is set, CHECK-enforced below.
      add(:muted_user_id, references(:users, on_delete: :delete_all))
      add(:muted_organization_id, references(:organizations, on_delete: :delete_all))

      add(
        :muted_remote_account_id,
        references(:fediverse_remote_accounts, on_delete: :delete_all)
      )

      add(:scope, :string, null: false, default: "all")

      timestamps()
    end

    create(
      constraint(:account_mutes, :exactly_one_target,
        check: """
        (muted_user_id IS NOT NULL)::int
          + (muted_organization_id IS NOT NULL)::int
          + (muted_remote_account_id IS NOT NULL)::int = 1
        """
      )
    )

    create(constraint(:account_mutes, :no_self_mute, check: "user_id <> muted_user_id"))

    # One row per reader and account: the scope is a property of that one row,
    # not a second row beside it, so widening a repost mute to the whole account
    # is an update. Partial, because two of the three columns are NULL on every
    # row and a plain unique index over the trio would let a reader mute the
    # same member twice.
    create(
      unique_index(:account_mutes, [:user_id, :muted_user_id],
        where: "muted_user_id IS NOT NULL",
        name: :account_mutes_user_member_index
      )
    )

    create(
      unique_index(:account_mutes, [:user_id, :muted_organization_id],
        where: "muted_organization_id IS NOT NULL",
        name: :account_mutes_user_organization_index
      )
    )

    create(
      unique_index(:account_mutes, [:user_id, :muted_remote_account_id],
        where: "muted_remote_account_id IS NOT NULL",
        name: :account_mutes_user_remote_account_index
      )
    )

    # What every feed source asks, once per page: "which accounts has this
    # reader silenced". The scope rides along because each source asks for one
    # of the two, so the answer is index-only.
    create(index(:account_mutes, [:user_id, :scope]))
  end
end
