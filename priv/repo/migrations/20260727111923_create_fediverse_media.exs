defmodule Vutuv.Repo.Migrations.CreateFediverseMedia do
  use Ecto.Migration

  # Pictures from the accounts a member follows (issue #1163): a post's image
  # attachments and one avatar per account.
  #
  # Until now everything cached from another network was text, because the reply
  # cards took the deliberate stance that no third party's picture is copied
  # here. That stance is right for a stranger who answered a post and wrong for
  # an account somebody chose to follow: for a reader who follows photographers,
  # the picture IS the post.
  #
  # So the pictures are downloaded and stored — and, exactly like a member's own
  # upload, held invisible until the AI image gate clears them
  # (`Vutuv.Moderation.ImageScans`). We publish nothing an unknown server sends
  # us sight unseen.
  #
  # New table + new nullable columns -> N-1 safe for the blue/green window.
  def change do
    create table(:fediverse_post_images) do
      add(
        :remote_post_id,
        references(:fediverse_posts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      # Where it was fetched from, and the order the author put them in.
      add(:source_uri, :text, null: false)
      add(:position, :integer, null: false, default: 0)
      # The author's own description of the picture. Kept because it is the
      # only thing that makes the image readable to somebody who cannot see it,
      # and losing it in transit would be a small act of vandalism.
      add(:alt, :text)

      # The stored file, as the content-fingerprinted name the served URL
      # carries (`<hash>.avif`) — the review-cover pattern, so the URL changes
      # whenever the bytes do. Nil while the fetch has not landed.
      add(:file, :string)
      add(:width, :integer)
      add(:height, :integer)

      # The AI gate's verdict for this picture: pending / approved, nil once
      # rejected (the row survives so the post keeps its shape, the file does
      # not). The display chokepoint reads it, never the file's presence.
      add(:moderation, :string)

      # The author marked it sensitive, or the post carries a content warning.
      # Independent of the gate: our model judging a picture safe does not
      # overrule the person who published it asking for it to be covered.
      add(:sensitive, :boolean, null: false, default: false)

      timestamps(updated_at: false)
    end

    create(unique_index(:fediverse_post_images, [:remote_post_id, :source_uri]))
    create(index(:fediverse_post_images, [:remote_post_id, :position]))

    alter table(:fediverse_remote_accounts) do
      # One small cached avatar per account, the same three columns a member's
      # own avatar uses: the fingerprinted file, its gate verdict, and where it
      # came from so a changed actor document refetches and an unchanged one
      # does not.
      add(:avatar, :string)
      add(:avatar_moderation, :string)
      add(:avatar_source, :text)
    end
  end
end
