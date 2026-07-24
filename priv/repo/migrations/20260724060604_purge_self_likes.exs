defmodule Vutuv.Repo.Migrations.PurgeSelfLikes do
  use Ecto.Migration

  # A member could like their own post until issue #1030, so `post_likes` holds
  # self-votes that inflate those posts' public like counts. Delete them once;
  # `Vutuv.Posts.like_post/2` now rejects the write, so none can reappear.
  # Irreversible (the removed rows carry no information worth restoring), hence
  # `up`/`down` rather than a reversible `change`.
  def up do
    execute("""
    DELETE FROM post_likes l
    USING posts p
    WHERE l.post_id = p.id AND l.user_id = p.user_id
    """)
  end

  def down, do: :ok
end
