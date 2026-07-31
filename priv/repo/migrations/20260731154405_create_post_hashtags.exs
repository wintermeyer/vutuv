defmodule Vutuv.Repo.Migrations.CreatePostHashtags do
  use Ecto.Migration

  # Which tags a member's post body mentions as `#hashtags`, so `/tags/:slug`
  # lists it.
  #
  # Until now a post reached a tag page only through the composer's tag field. A
  # `#berlin` written in the body linked TO `/tags/berlin` and was then missing
  # FROM it — the reader followed the link the post itself offered and did not
  # find the post they had clicked it in.
  #
  # Its own table rather than a row in `post_tags`, and that is the whole reason
  # it exists: `post_tags` is what the card renders as tag chips under a post. A
  # hashtag is already visible in the text, so filing it there would print every
  # hashtag twice — once in the sentence the member wrote and once as a chip
  # they did not. So the two filings stay apart: `post_tags` is "the author filed
  # this post under this tag", this is "the author's text names this tag", and
  # `Vutuv.Posts.visible_tagged_posts_query/0` unions them for every reader that
  # asks which posts carry a tag.
  #
  # Like the fediverse side, only tags that ALREADY exist here are filed
  # (`Vutuv.Tags.tag_ids_for_hashtags/1`): a typo in a body must not leave a tag
  # page behind, and the composer's tag field stays the place a member
  # deliberately names a new tag.
  #
  # New table only -> N-1 safe for the blue/green window.
  def change do
    create table(:post_hashtags) do
      add(:post_id, references(:posts, type: :binary_id, on_delete: :delete_all), null: false)
      add(:tag_id, references(:tags, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps()
    end

    # One row per (post, tag): a body repeating its own hashtag is one filing,
    # and the re-derivation on every edit leans on this to be idempotent.
    create(unique_index(:post_hashtags, [:post_id, :tag_id]))

    # The tag page's read: every post whose body names one tag.
    create(index(:post_hashtags, [:tag_id, :post_id]))
  end
end
