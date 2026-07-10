defmodule Vutuv.Repo.Migrations.CreatePostScreenshots do
  use Ecto.Migration

  # The durable queue + attachment record for a post's auto link screenshot
  # (Vutuv.Posts.Screenshots): one row per qualifying post (a single URL, no
  # image). A `pending`/`capturing`/`failed` row is a queued job the worker
  # drains; a `ready` row carries the stored screenshot. Additive only, so the
  # currently deployed release keeps working (N-1 compatible).
  def change do
    create table(:post_screenshots) do
      add(:post_id, references(:posts, on_delete: :delete_all), null: false)

      # The captured URL. `text`, not varchar(255): a body URL can legitimately
      # run long (query strings), and Ecto does not enforce a column limit.
      add(:url, :text, null: false)
      add(:status, :string, null: false, default: "pending")
      # The stored "<hash><ext>" (Vutuv.Screenshot), nil until ready.
      add(:screenshot, :string)
      add(:width, :integer)
      add(:height, :integer)
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime)
      add(:last_error, :string)
      add(:captured_at, :utc_datetime)

      timestamps()
    end

    # One screenshot per post.
    create(unique_index(:post_screenshots, [:post_id]))
    # The poller claims due rows by (status, next_attempt_at).
    create(index(:post_screenshots, [:status, :next_attempt_at]))
  end
end
