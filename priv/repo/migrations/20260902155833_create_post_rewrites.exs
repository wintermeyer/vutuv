defmodule Vutuv.Repo.Migrations.CreatePostRewrites do
  use Ecto.Migration

  # A member's private search-and-replace rules for one author's posts: the
  # regex rewrites `Vutuv.PostRewrites` applies to the text of a post before it
  # renders for THAT member (a Flipboard footer under every Golem post, a
  # signature, a hashtag wall). Viewer-only like the content filters: the stored
  # post is never touched, nobody else sees the change, and the list rides in
  # the GDPR export.
  #
  # New table, plain addition -> N-1 safe for the blue/green window.
  def change do
    create table(:post_rewrites) do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      # Whose posts the rule reads: the author's handle as the app spells it
      # (`@golemde@flipboard.com` for an account elsewhere, `@handle` for a
      # member or a page), downcased. A handle rather than a foreign key so one
      # column names any of the three author kinds.
      add(:account, :string, null: false)
      # A PCRE pattern (flags: unicode, multiline) and what each match becomes.
      add(:pattern, :string, null: false)
      add(:replacement, :string, null: false, default: "")
      # Rules run top to bottom within an account, each on the previous one's
      # output; set programmatically, never cast.
      add(:position, :integer, null: false)

      timestamps()
    end

    # The feed compiles a member's whole list on every page, so read them by
    # owner in one shot.
    create(index(:post_rewrites, [:user_id]))
  end
end
