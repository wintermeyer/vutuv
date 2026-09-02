defmodule Vutuv.Videos do
  @moduledoc """
  Video on posts (issue #1906): the clip a post carries, from the composer's
  upload to the four files a page offers.

  ## The shape

  A clip is uploaded eagerly, like a photo: `create_pending_video/3` keeps
  the original, probes it and inserts a `Vutuv.Posts.PostVideo` row with no
  post yet, and `Vutuv.Videos.Pipeline` starts on it while the author is
  still writing. The pipeline (`Vutuv.Videos.Job`) pulls the stills the AI
  check judges, writes the H.264 file, and the clip is **ready** when both
  have landed; the AV1 file and the two 360p files follow as enhancements. A
  post with a clip is created only once the clip is ready — until then the
  composer's submission waits as a `Vutuv.Posts.PendingVideoPost`, which
  `Vutuv.Videos.Publisher` turns into the post.

  ## Who hears about it

  Every change of state is broadcast on the author's video topic
  (`subscribe/1`): the composer's tile, the pending card in the feed and the
  progress chip in the app bar all draw from the same `{:post_video, summary}`
  message, and a pending post's fate arrives as `{:pending_video_post, …}`.

  ## Off switch

  `enabled?/0` is the product flag **and** the presence of ffmpeg: an
  installation without the binary simply has no video, which is what an
  air-gapped intranet gets without setting anything.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Accounts.User
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts
  alias Vutuv.Posts.PendingVideoPost
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostDraft
  alias Vutuv.Posts.PostVideo
  alias Vutuv.Posts.PostVideoFrame
  alias Vutuv.PostVideoStore
  alias Vutuv.Repo
  alias Vutuv.Videos.FFmpeg
  alias Vutuv.Videos.Pipeline
  alias Vutuv.Videos.Publisher

  @pubsub Vutuv.PubSub
  @pending_max_age_hours 24
  # How many stills at most, how far apart the fixed ones sit, and how many
  # opening seconds the default cover is picked from.
  @max_frames 24
  @frame_interval_seconds 20
  @cover_window_seconds 5
  # A job that has not written its heartbeat for this long lost its process
  # (a deploy, a crash) and is claimed again. Longer than any single step
  # takes between heartbeats — scene detection on a two-minute 4K clip was
  # 27 s on the production host — so a slot switch cannot steal a live job.
  @stale_after_seconds 180

  ## Configuration

  @doc "Whether members can attach a video: the flag is on and ffmpeg is there."
  def enabled?, do: flag?() and FFmpeg.available?()

  defp flag?, do: Keyword.get(config(), :enabled, true)

  def max_filesize, do: Keyword.fetch!(config(), :max_filesize)
  def max_duration_seconds, do: Keyword.fetch!(config(), :max_duration_seconds)
  def concurrency, do: max(1, Keyword.get(config(), :concurrency, 2))
  def max_frames, do: @max_frames
  def frame_interval_seconds, do: @frame_interval_seconds
  def cover_window_seconds, do: @cover_window_seconds
  def stale_after_seconds, do: @stale_after_seconds
  defdelegate extension_whitelist, to: PostVideoStore
  defp config, do: Application.fetch_env!(:vutuv, :post_videos)

  @doc "The MIME types the API announces as accepted."
  def mime_types, do: ~w(video/mp4 video/quicktime video/webm video/x-m4v)

  ## PubSub

  def topic(user_id), do: "post_video:#{user_id}"
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(user_id))
  def broadcast(nil, _event), do: :ok
  def broadcast(user_id, event), do: Phoenix.PubSub.broadcast(@pubsub, topic(user_id), event)

  ## The upload

  @doc """
  Keeps the upload at `path`, probes it and queues the pipeline. Returns
  `{:ok, video}`, or `{:error, :too_large | :too_long | :invalid_file |
  :disabled}`. Size is refused before anything is read, length after ffprobe.
  """
  def create_pending_video(%User{} = user, path, filename) do
    cond do
      not enabled?() ->
        {:error, :disabled}

      File.stat!(path).size > max_filesize() ->
        {:error, :too_large}

      not Vutuv.Uploads.valid_extension?(filename, extension_whitelist()) ->
        {:error, :invalid_file}

      true ->
        with {:ok, facts} <- probe(path),
             :ok <- check_length(facts) do
          store_and_insert(user, path, filename, facts)
        end
    end
  end

  defp probe(path) do
    case FFmpeg.probe(path) do
      {:ok, facts} -> {:ok, facts}
      {:error, _reason} -> {:error, :invalid_file}
    end
  end

  defp check_length(%{duration_ms: ms}) do
    if ms > max_duration_seconds() * 1000, do: {:error, :too_long}, else: :ok
  end

  defp store_and_insert(user, path, filename, facts) do
    token = PostVideo.gen_token()

    with {:ok, meta} <- PostVideoStore.store_original(path, filename, token) do
      insert =
        %PostVideo{user_id: user.id, token: token, moderation: ImageScans.initial_state()}
        |> Ecto.Changeset.change(
          Map.merge(meta, %{
            duration_ms: facts.duration_ms,
            width: facts.width,
            height: facts.height
          })
        )
        |> Repo.insert()

      case insert do
        {:ok, video} ->
          Pipeline.nudge()
          {:ok, video}

        {:error, _} = error ->
          PostVideoStore.delete(token)
          error
      end
    end
  end

  ## Reading

  def get_video(id) do
    Vutuv.UUIDv7.with_cast(id, fn id ->
      PostVideo |> Repo.get(id) |> Repo.preload(:frames)
    end)
  end

  def get_video_by_token(token) when is_binary(token) do
    PostVideo |> Repo.get_by(token: token) |> Repo.preload([:frames, post: :user])
  end

  def get_video_by_token(_token), do: nil

  @doc "The author's own still-unattached clip by id, or `nil` — the draft-restore check."
  def pending_video(%User{} = author, id) do
    Vutuv.UUIDv7.with_cast(id, fn id ->
      from(v in PostVideo, where: v.id == ^id and v.user_id == ^author.id and is_nil(v.post_id))
      |> Repo.one()
      |> Repo.preload(:frames)
    end)
  end

  def pending_video(_author, _id), do: nil

  @doc "A post's clip with its frames, or `nil`; takes the post or its id."
  def video_of(%Post{video: %PostVideo{} = video}), do: Repo.preload(video, :frames)
  def video_of(%Post{id: id}), do: video_of(id)

  def video_of(post_id) when is_binary(post_id) do
    from(v in PostVideo, where: v.post_id == ^post_id) |> Repo.one() |> Repo.preload(:frames)
  end

  def video_of(_), do: nil

  ## The author's choices

  def update_alt(%PostVideo{} = video, alt) do
    video |> PostVideo.alt_changeset(%{alt: alt}) |> Repo.update()
  end

  @doc """
  Makes the still `frame_id` the cover: cuts the poster from it and records
  the choice. Only one of this clip's own frames is accepted.
  """
  def choose_cover(%PostVideo{} = video, frame_id) do
    frames = frames_of(video)

    case Enum.find(frames, &(&1.id == frame_id)) do
      nil ->
        {:error, :unknown_frame}

      frame ->
        with :ok <- PostVideoStore.write_cover(video.token, frame.position) do
          video
          |> Ecto.Changeset.change(
            cover_frame_id: frame.id,
            cover_written_at: DateTime.utc_now(:second)
          )
          |> Repo.update()
          |> tap(fn
            {:ok, updated} -> broadcast_progress(updated)
            _ -> :ok
          end)
        end
    end
  end

  defp frames_of(%PostVideo{frames: frames}) when is_list(frames), do: frames
  defp frames_of(%PostVideo{} = video), do: Repo.preload(video, :frames).frames

  @doc "The frame the cover is cut from, or `nil` before the frames exist."
  def cover_frame(%PostVideo{cover_frame_id: nil}), do: nil

  def cover_frame(%PostVideo{cover_frame_id: id} = video) do
    Enum.find(frames_of(video), &(&1.id == id))
  end

  @doc "Removes the author's own unattached clip, files and all. A no-op for anybody else's."
  def delete_pending_video(%PostVideo{post_id: nil} = video) do
    Repo.delete(video, allow_stale: true)
    PostVideoStore.delete(video.token)
    :ok
  end

  def delete_pending_video(%PostVideo{}), do: :ok

  @doc "The files behind a post's clip go with the post (`Vutuv.Posts.delete_post/1`)."
  def delete_files(%PostVideo{token: token}), do: PostVideoStore.delete(token)

  @doc """
  Removes unattached clips older than a day, unless a draft or a waiting
  pending post still names them. Returns the number swept.
  """
  def sweep_pending_videos(max_age_hours \\ @pending_max_age_hours) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -max_age_hours * 3600, :second)

    from(v in PostVideo,
      as: :video,
      where: is_nil(v.post_id) and v.inserted_at < ^cutoff,
      where: not exists(from(d in PostDraft, where: d.video_id == parent_as(:video).id)),
      where:
        not exists(
          from(p in PendingVideoPost,
            where: p.video_id == parent_as(:video).id and p.status == "waiting"
          )
        )
    )
    |> Repo.all()
    |> Enum.map(&delete_pending_video/1)
    |> length()
  end

  ## Visibility

  @doc """
  Who may see the clip: while it is unattached its uploader (and an admin);
  once it belongs to a post, whoever may see the post.
  """
  def visible_to?(%PostVideo{post_id: nil} = video, viewer), do: owner_or_admin?(video, viewer)

  def visible_to?(%PostVideo{} = video, viewer) do
    case post_of(video) do
      %Post{} = post -> Posts.visible_to?(post, viewer)
      nil -> false
    end
  end

  def owner_or_admin?(%PostVideo{user_id: owner}, %User{id: owner}), do: true
  def owner_or_admin?(%PostVideo{}, %User{admin?: true}), do: true
  def owner_or_admin?(%PostVideo{}, _viewer), do: false

  defp post_of(%PostVideo{post: %Post{} = post}), do: post
  defp post_of(%PostVideo{post_id: id}), do: Posts.get_post(id)

  ## Progress

  @doc "What every listener hears about a clip: enough to draw a tile, never the row."
  def summary(%PostVideo{} = video) do
    frames = frames_of(video)

    %{
      id: video.id,
      token: video.token,
      stage: video.stage,
      progress: video.progress,
      moderation: video.moderation,
      rejected_second: video.rejected_second,
      error: video.error,
      duration_ms: video.duration_ms,
      frames: length(frames),
      checked: Enum.count(frames, &(&1.moderation != "pending")),
      cover_frame_id: video.cover_frame_id
    }
  end

  def broadcast_progress(%PostVideo{} = video) do
    broadcast(video.user_id, {:post_video, summary(video)})
  end

  @doc "How far the check has got: `%{total:, checked:}` over the clip's frames."
  def check_progress(%PostVideo{} = video) do
    frames = frames_of(video)
    %{total: length(frames), checked: Enum.count(frames, &(&1.moderation != "pending"))}
  end

  ## Pipeline bookkeeping (Vutuv.Videos.Job / Pipeline)

  @doc """
  Claims up to `limit` clips with work left, oldest first and those still
  missing their H.264 file before everything else — a post is waiting on
  that one; the enhancements can queue. A claim is a compare-and-set on
  `worked_at`, so two slots of a deploy overlap can never work the same clip.
  """
  def claim_due(limit) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now(:second)
    stale = DateTime.add(now, -@stale_after_seconds, :second)

    from(v in PostVideo,
      where: v.stage not in ["rejected", "failed"],
      where:
        is_nil(v.frames_extracted_at) or is_nil(v.h264_ready_at) or is_nil(v.av1_ready_at) or
          is_nil(v.lite_ready_at),
      where: is_nil(v.worked_at) or v.worked_at < ^stale,
      order_by: [asc: fragment("? IS NOT NULL", v.h264_ready_at), asc: v.inserted_at],
      limit: ^(limit * 2)
    )
    |> Repo.all()
    |> Enum.reduce_while([], fn video, claimed ->
      if length(claimed) >= limit do
        {:halt, claimed}
      else
        case claim(video, now) do
          {:ok, video} -> {:cont, [video | claimed]}
          :taken -> {:cont, claimed}
        end
      end
    end)
    |> Enum.reverse()
  end

  defp claim(%PostVideo{worked_at: nil} = video, now) do
    from(v in PostVideo, where: v.id == ^video.id and is_nil(v.worked_at))
    |> Repo.update_all(set: [worked_at: now])
    |> claimed(video, now)
  end

  defp claim(%PostVideo{worked_at: seen} = video, now) do
    from(v in PostVideo, where: v.id == ^video.id and v.worked_at == ^seen)
    |> Repo.update_all(set: [worked_at: now])
    |> claimed(video, now)
  end

  defp claimed({1, _}, video, now), do: {:ok, %{video | worked_at: now}}
  defp claimed(_, _video, _now), do: :taken

  @doc "Refreshes the job's heartbeat, so the claim stays with the process doing the work."
  def heartbeat(%PostVideo{id: id}) do
    from(v in PostVideo, where: v.id == ^id)
    |> Repo.update_all(set: [worked_at: DateTime.utc_now(:second)])

    :ok
  end

  @doc "Gives the claim back: the job finished (or found nothing left to do)."
  def release(%PostVideo{id: id}) do
    from(v in PostVideo, where: v.id == ^id) |> Repo.update_all(set: [worked_at: nil])
    :ok
  end

  @doc "Writes `changes` on the row and tells every listener. Returns the fresh row."
  def update_state(%PostVideo{} = video, changes) when is_list(changes) do
    {:ok, updated} = video |> Ecto.Changeset.change(changes) |> Repo.update()
    updated = %{updated | frames: frames_of(video)}
    broadcast_progress(updated)
    updated
  end

  @doc "The H.264 rendition's percent, written at most every few points and broadcast."
  def set_progress(%PostVideo{} = video, percent) when is_integer(percent) do
    from(v in PostVideo, where: v.id == ^video.id)
    |> Repo.update_all(set: [progress: percent, worked_at: DateTime.utc_now(:second)])

    updated = %{video | progress: percent}
    broadcast_progress(updated)
    updated
  end

  @doc """
  Records the stills the job pulled (`[%{position:, seconds:, scene_cut:}]`,
  in order), picks the default cover, and queues one AI scan per frame. Frames
  start `approved` when the check is off, so the clip's verdict is decided the
  same way either way (`recompute_moderation/1`).
  """
  def record_frames(%PostVideo{} = video, frames, cover_position) when is_list(frames) do
    now = DateTime.utc_now(:second)
    state = ImageScans.initial_state()

    rows =
      Repo.transaction(fn ->
        Repo.delete_all(from(f in PostVideoFrame, where: f.video_id == ^video.id))

        Enum.map(frames, fn frame ->
          Repo.insert!(%PostVideoFrame{
            video_id: video.id,
            position: frame.position,
            seconds: frame.seconds,
            scene_cut: frame.scene_cut,
            moderation: state
          })
        end)
      end)

    with {:ok, rows} <- rows do
      cover = Enum.find(rows, &(&1.position == cover_position)) || List.first(rows)

      video =
        update_state(%{video | frames: rows},
          frames_extracted_at: now,
          cover_frame_id: cover && cover.id
        )

      Enum.each(rows, &ImageScans.enqueue("post_video_frame", &1.id, video.user_id))
      {:ok, recompute_moderation(video)}
    end
  end

  @doc """
  The clip's verdict from its frames: one rejected frame rejects the clip,
  all approved approves it, anything else is still pending. Called after
  every frame verdict and once the frames are recorded.
  """
  def recompute_moderation(%PostVideo{id: id}) do
    video = get_video(id)
    frames = video.frames

    verdict =
      cond do
        frames == [] -> "pending"
        Enum.any?(frames, &(&1.moderation == "rejected")) -> "rejected"
        Enum.all?(frames, &(&1.moderation == "approved")) -> "approved"
        true -> "pending"
      end

    video =
      if verdict != video.moderation,
        do: update_state(video, moderation: verdict),
        else: video

    settle(video)
  end

  @doc """
  A frame passed the check (`Vutuv.Moderation.ImageSubjects`): flips it,
  re-derives the clip's verdict. `:stale` when the frame is gone.
  """
  def frame_approved(frame_id) do
    flipped =
      from(f in PostVideoFrame, where: f.id == ^frame_id and f.moderation == "pending")
      |> Repo.update_all(set: [moderation: "approved"])

    case flipped do
      {1, _} ->
        case Repo.get(PostVideoFrame, frame_id) do
          %PostVideoFrame{video_id: video_id} -> recompute_moderation(%PostVideo{id: video_id})
          nil -> :ok
        end

        :ok

      _ ->
        :stale
    end
  end

  @doc """
  A frame failed the check: the whole clip is refused at that second, and
  every file of it goes — renditions, cover, stills and the original
  (`Vutuv.PostVideoStore.delete/1`), nothing unsafe stays at rest. The row
  stays, so the composer and the pending card can say what happened and offer
  the text a way out. `:stale` when the frame is gone.
  """
  def frame_rejected(frame_id) do
    case Repo.get(PostVideoFrame, frame_id) do
      nil ->
        :stale

      %PostVideoFrame{} = frame ->
        from(f in PostVideoFrame, where: f.id == ^frame.id)
        |> Repo.update_all(set: [moderation: "rejected"])

        case get_video(frame.video_id) do
          nil ->
            :stale

          video ->
            PostVideoStore.delete(video.token)

            video
            |> update_state(
              moderation: "rejected",
              stage: "rejected",
              rejected_second: frame.seconds,
              worked_at: nil
            )
            |> broadcast_progress()

            :ok
        end
    end
  end

  @doc """
  Decides the clip's stage from what is on the row: `ready` once the H.264
  file exists and the check passed (and publishes every post waiting on it),
  `checking` while the file waits for the verdict. Called by the job after
  the H.264 rendition and by every frame verdict, so whichever lands last
  releases the clip.
  """
  def settle(%PostVideo{} = video) do
    video = get_video(video.id) || video

    cond do
      video.stage in ["rejected", "failed", "ready"] ->
        video

      video.h264_ready_at != nil and video.moderation == "approved" ->
        ready = update_state(video, stage: "ready", progress: 100)
        Publisher.publish_for(ready)
        ready

      video.h264_ready_at != nil and video.moderation == "pending" ->
        if video.stage != "checking", do: update_state(video, stage: "checking"), else: video

      true ->
        video
    end
  end

  @doc "The job could not finish the clip; the text keeps a way out (`Vutuv.Posts.PendingVideoPost`)."
  def fail(%PostVideo{} = video, reason) do
    Logger.warning("post_video failed video=#{video.id} reason=#{inspect(reason)}")
    update_state(video, stage: "failed", error: clip(inspect(reason)), worked_at: nil)
  end

  defp clip(text), do: String.slice(text, 0, 2_000)

  ## Pending posts (issue #1910)

  @doc """
  Stores the composer's submission until its clip is ready: the create path
  (`kind`), its `context` (`parent`, `organization`, `note`, `remote_post` —
  whichever the kind needs) and the attrs verbatim. Publishes on the spot when
  the clip turned ready meanwhile.
  """
  def create_pending_post(%User{} = user, %PostVideo{} = video, kind, context, attrs)
      when is_map(context) and is_map(attrs) do
    params = %{
      kind: kind,
      parent_post_id: context[:parent] && context[:parent].id,
      organization_id: context[:organization] && context[:organization].id,
      note_id: context[:note] && context[:note].id,
      remote_post_id: context[:remote_post] && context[:remote_post].id,
      attrs: json_attrs(attrs)
    }

    insert =
      %PendingVideoPost{user_id: user.id, video_id: video.id}
      |> PendingVideoPost.changeset(params)
      |> Repo.insert()

    with {:ok, pending} <- insert do
      broadcast(user.id, {:pending_video_post, pending_summary(pending)})
      # The clip may have turned ready between the composer's check and this
      # insert; the publisher's claim makes a double publish impossible.
      if PostVideo.ready?(get_video(video.id) || video), do: Publisher.publish(pending)
      {:ok, pending}
    end
  end

  # The map column round-trips through JSON: string keys, and nothing but
  # what JSON can carry.
  defp json_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Jason.encode!()
    |> Jason.decode!()
  end

  @doc "What listeners hear about a pending post."
  def pending_summary(%PendingVideoPost{} = pending) do
    %{id: pending.id, status: pending.status, post_id: pending.post_id, video_id: pending.video_id}
  end

  @doc "The member's posts still waiting on a clip (or refused one), newest first, clips preloaded."
  def pending_posts_for(%User{id: user_id}), do: pending_posts_for(user_id)

  def pending_posts_for(user_id) when is_binary(user_id) do
    from(p in PendingVideoPost,
      where: p.user_id == ^user_id and p.status == "waiting",
      order_by: [desc: p.inserted_at],
      preload: [video: :frames]
    )
    |> Repo.all()
  end

  def get_pending_post(%User{id: user_id}, id) do
    Vutuv.UUIDv7.with_cast(id, fn id ->
      from(p in PendingVideoPost, where: p.id == ^id and p.user_id == ^user_id)
      |> Repo.one()
      |> Repo.preload(video: :frames)
    end)
  end

  @doc """
  The app bar's line: how many of the member's posts wait on a clip, and the
  percent of the one being converted (`nil` when nothing is converting).
  """
  def in_progress_summary(user_id) when is_binary(user_id) do
    videos =
      from(p in PendingVideoPost,
        join: v in PostVideo,
        on: v.id == p.video_id,
        where: p.user_id == ^user_id and p.status == "waiting",
        where: v.stage not in ["rejected", "failed"],
        select: %{stage: v.stage, progress: v.progress}
      )
      |> Repo.all()

    converting = Enum.filter(videos, &(&1.stage == "transcoding"))

    %{
      count: length(videos),
      progress:
        case converting do
          [] -> nil
          list -> div(Enum.sum(Enum.map(list, & &1.progress)), length(list))
        end
    }
  end

  def in_progress_summary(_), do: %{count: 0, progress: nil}

  @doc "Drops a waiting post and its clip, files and all."
  def cancel_pending_post(%PendingVideoPost{status: "waiting"} = pending) do
    {count, _} =
      from(p in PendingVideoPost, where: p.id == ^pending.id and p.status == "waiting")
      |> Repo.update_all(set: [status: "canceled"])

    if count == 1 do
      pending = Repo.preload(pending, :video)
      if pending.video, do: delete_pending_video(pending.video)
      broadcast(pending.user_id, {:pending_video_post, %{pending_summary(pending) | status: "canceled"}})
    end

    :ok
  end

  def cancel_pending_post(%PendingVideoPost{}), do: :ok

  @doc "Publishes the waiting text as it is, without the clip, which goes."
  def publish_without_video(%PendingVideoPost{status: "waiting"} = pending) do
    Publisher.publish(pending, without_video: true)
  end

  def publish_without_video(%PendingVideoPost{}), do: {:error, :not_waiting}
end
