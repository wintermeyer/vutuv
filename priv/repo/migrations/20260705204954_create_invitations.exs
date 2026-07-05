defmodule Vutuv.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  # One row per email address ever invited (issue: invitation system). We store
  # only a SHA-256 hash of the normalized address, never the plaintext, so a DB
  # leak cannot reveal who was invited. The unique index enforces the
  # "invite each address at most once, site-wide" rule; `visited_at` is stamped
  # the first time the invited person opens the prefilled sign-up link.
  def change do
    create table(:invitations) do
      add(:user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false)
      add(:email_hash, :string, null: false)
      add(:locale, :string, null: false)
      add(:auto_follow, :boolean, null: false, default: false)
      add(:visited_at, :naive_datetime)
      timestamps()
    end

    create(unique_index(:invitations, [:email_hash]))
    # The per-inviter daily cap counts a member's rows within a Berlin day.
    create(index(:invitations, [:user_id, :inserted_at]))
  end
end
