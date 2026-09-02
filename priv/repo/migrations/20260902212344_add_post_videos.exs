defmodule Vutuv.Repo.Migrations.AddPostVideos do
  use Ecto.Migration

  # Video on posts (issue #1906). Three new tables and one nullable column:
  # all additions, so N-1 safe for the blue/green window.
  #
  # `post_videos` is the clip itself, uploaded eagerly like a post image
  # (`post_id` stays nil until the post is submitted) and worked on by
  # `Vutuv.Videos.Pipeline` — every step it completes is stamped in its own
  # column, so a job a deploy kills mid-way is resumed from the step it lost,
  # never from the start. `post_video_frames` are the stills pulled for the AI
  # check (issue #1908) and the strip the author picks the cover from (#1909);
  # one row per frame, because the scan queue keys one open scan per subject.
  # `pending_video_posts` is the post as a job (#1910): the composer's text
  # and choices wait here until the clip is ready and a worker turns the row
  # into a real post, so no feed or profile query needs a new filter.
  def change do
    create table(:post_videos) do
      add(:post_id, references(:posts, type: :binary_id, on_delete: :delete_all))
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      # The lookup key and on-disk directory name, never the row id.
      add(:token, :string, null: false)
      add(:alt, :string, null: false, default: "")

      # What was uploaded: the container's MIME type and size, and what
      # ffprobe read from it. `width`/`height` are the source's, after the
      # rotation its metadata asks for.
      add(:content_type, :string)
      add(:size_bytes, :bigint)
      add(:duration_ms, :integer)
      add(:width, :integer)
      add(:height, :integer)

      # Where the pipeline is: queued | frames | transcoding | checking |
      # ready | rejected | failed. `progress` is the H.264 rendition's percent
      # while `transcoding`, the one the author watches.
      add(:stage, :string, null: false, default: "queued")
      add(:progress, :integer, null: false, default: 0)
      add(:error, :text)

      # The AI verdict over all frames: pending | approved | rejected, and for
      # a rejection the second the refused frame sits at.
      add(:moderation, :string, null: false, default: "pending")
      add(:rejected_second, :integer)

      # One stamp per completed step; nil means still to do. The sweeper's due
      # query reads these, the stage above is for people.
      add(:frames_extracted_at, :utc_datetime)
      add(:h264_ready_at, :utc_datetime)
      add(:av1_ready_at, :utc_datetime)
      add(:lite_ready_at, :utc_datetime)
      add(:cover_written_at, :utc_datetime)

      # The pipeline's heartbeat: set when a worker claims the row, refreshed
      # on every progress tick, so a row nobody has touched for a few minutes
      # is a job whose process died and is claimed again.
      add(:worked_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:post_videos, [:token]))
    create(index(:post_videos, [:post_id]))
    # The abandoned-composer sweep, like the pending-image one.
    create(index(:post_videos, [:inserted_at], where: "post_id IS NULL"))
    # The pipeline's due query: unfinished work first.
    create(index(:post_videos, [:stage, :worked_at]))

    create table(:post_video_frames) do
      add(
        :video_id,
        references(:post_videos, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      # Order in the strip, the second in the clip it was taken at, and
      # whether a scene cut put it there (the rest are the fixed 20-second
      # ticks and the opening frame).
      add(:position, :integer, null: false)
      add(:seconds, :integer, null: false)
      add(:scene_cut, :boolean, null: false, default: false)
      add(:moderation, :string, null: false, default: "pending")

      timestamps()
    end

    create(unique_index(:post_video_frames, [:video_id, :position]))

    alter table(:post_videos) do
      # The frame the cover is cut from; nil until the frames exist. The
      # default is the pipeline's pick (the `thumbnail` filter over the opening
      # seconds), the author's click replaces it.
      add(
        :cover_frame_id,
        references(:post_video_frames, type: :binary_id, on_delete: :nilify_all)
      )
    end

    create table(:pending_video_posts) do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      # Nullable: a canceled row loses its clip, a "publish without video" one
      # too, and the row is the record of what happened.
      add(:video_id, references(:post_videos, type: :binary_id, on_delete: :nilify_all))

      # Which of the composer's create paths the post takes once the clip is
      # ready, and the context that path needs: post | reply |
      # organization_post | remote_reply | remote_post_reply.
      add(:kind, :string, null: false)
      add(:parent_post_id, references(:posts, type: :binary_id, on_delete: :nilify_all))

      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )

      add(:note_id, references(:fediverse_notes, type: :binary_id, on_delete: :nilify_all))

      add(
        :remote_post_id,
        references(:fediverse_posts, type: :binary_id, on_delete: :nilify_all)
      )

      # The composer's attrs, verbatim: body, tags, license, language,
      # denials, image_ids, layout, fill. The same map `Posts.create_post/2`
      # takes, so publishing is that call with the video added.
      add(:attrs, :map, null: false, default: %{})

      # waiting | published | failed | canceled
      add(:status, :string, null: false, default: "waiting")
      add(:post_id, references(:posts, type: :binary_id, on_delete: :nilify_all))
      add(:error, :text)

      timestamps()
    end

    create(index(:pending_video_posts, [:user_id, :status]))
    create(index(:pending_video_posts, [:video_id]))

    alter table(:post_drafts) do
      # A draft names the clip it holds, like the photos it names by id, so a
      # reload brings the video back with its progress (issue #1148).
      add(:video_id, references(:post_videos, type: :binary_id, on_delete: :nilify_all))
    end
  end
end
