defmodule Vutuv.Posts.Pending do
  @moduledoc """
  The post that waits for its media, and the four places its author watches it
  wait (issue #2106).

  A post with photos alone publishes at once and its pictures catch up
  pixelated (#1720). A post with a clip or with files cannot: the clip has to
  be converted and checked, a file has to be rendered into preview pages
  (#2105) and every one of those pages has to pass the AI check. That is ten or
  twenty minutes in which nothing is in the feed, so the submission is parked
  as a `Vutuv.Posts.PendingPost` and `Vutuv.Posts.Publisher` turns it into the
  post the moment the last medium is done.

  ## One row, any media

  This generalises the row that used to wait for a clip alone (#1910). The clip
  is now one case: `state/1` asks the video **and** every file, and answers
  `:ready` only when none of them is still working. A file is done when its
  render reached a terminal stage *and* no preview page of it is still waiting
  for a verdict — the pages are what a reader sees under the post, so a post
  that published before them would show pixelated stand-ins where its author
  expected pages.

  ## One author topic

  Everything the author's four surfaces draw from goes out on `topic/1` — the
  composer tile, the waiting card above the feed, the app-bar chip and
  `/system/uploads`. `{:post_video, …}` (a clip moved), `{:attachment, …}` (a
  file moved) and `{:pending_post, …}` (a waiting post's fate) are the three
  messages, and `Vutuv.Videos` broadcasts on this same topic rather than one of
  its own.

  ## Surviving a deploy

  Waiting is by definition work that outlives the request that started it, so
  the recovery is the shape `Vutuv.Newsletters.BroadcastResumer` established:

    * the **row** carries the state (`status`), never a process;
    * the due list is a **query** (`due/1`), so a slot that dies holds nothing;
    * publishing is claimed by a compare-and-set on `status`, so the two slots
      of a blue/green overlap cannot publish the same text;
    * a claim that has stood longer than one publish can possibly take is
      resumed — and because the claim also wrote the post's id, the resume can
      tell "the post is already there" from "it never happened" instead of
      writing the member's post twice.

  ## The clock advances on every outcome

  `due/1` is oldest-clock-first, and `sweep/1` stamps `checked_at` on every row
  it looks at — **including the ones it can do nothing for**, which is most of
  them: a file that is still rendering will still be rendering in a second. A
  pass that wrote no clock there would hand the same rows back to every batch
  for ever and spend the cap on work that cannot complete, which is the
  deadlock `CLAUDE.md` records from `Vutuv.Fediverse.refresh_counts/1`.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.Pages
  alias Vutuv.Images.Image
  alias Vutuv.Posts.PendingPost
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostVideo
  alias Vutuv.Posts.Publisher
  alias Vutuv.Repo
  alias Vutuv.UUIDv7
  alias Vutuv.Videos

  @pubsub Vutuv.PubSub

  # How long a row is left alone after the sweeper has looked at it. Short
  # enough that a medium finishing on a quiet installation is noticed within a
  # minute even if every direct nudge was lost with its process.
  @recheck_seconds 30
  # How long a `publishing` claim stands before another slot may take it over.
  # A publish is one insert and a handful of broadcasts — milliseconds — so
  # this is orders of magnitude longer than one item takes, which is what makes
  # the resume safe while the old slot of a deploy is still working.
  @stale_after_seconds 300
  # What the author's page shows of their own history at once.
  @history_limit 50

  @doc "How long a claim stands before the sweeper resumes it."
  def stale_after_seconds, do: @stale_after_seconds

  ## PubSub — the one author topic

  @doc "Everything about this member's media in flight goes out here."
  def topic(user_id), do: "post_media:#{user_id}"
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(user_id))
  def broadcast(nil, _event), do: :ok
  def broadcast(user_id, event), do: Phoenix.PubSub.broadcast(@pubsub, topic(user_id), event)

  @doc "What listeners hear about a waiting post."
  def summary(%PendingPost{} = pending) do
    %{
      id: pending.id,
      status: pending.status,
      post_id: pending.post_id,
      video_id: pending.video_id
    }
  end

  @doc "Tells the author's surfaces where this row got to."
  def broadcast_summary(%PendingPost{} = pending),
    do: broadcast(pending.user_id, {:pending_post, summary(pending)})

  @doc "Tells them a file of theirs moved (rendered a page, cleared the check, was refused)."
  def broadcast_attachment(%Attachment{} = attachment) do
    broadcast(
      attachment.user_id,
      {:attachment,
       %{
         id: attachment.id,
         stage: attachment.stage,
         refused?: Attachment.refused?(attachment)
       }}
    )
  end

  ## Creating

  @doc """
  Parks the composer's submission until its media are done: the create path
  (`kind`), its `context` (`parent`, `organization`, `note`, `remote_post` —
  whichever the kind needs), the attrs verbatim, and the media it waits for
  (`:video`, `:attachments`). Publishes on the spot when they turned out to be
  done already.
  """
  def create(%User{} = user, kind, context, attrs, opts \\ [])
      when is_map(context) and is_map(attrs) do
    video = Keyword.get(opts, :video)
    attachments = Keyword.get(opts, :attachments, [])

    params = %{
      kind: kind,
      parent_post_id: context[:parent] && context[:parent].id,
      organization_id: context[:organization] && context[:organization].id,
      note_id: context[:note] && context[:note].id,
      remote_post_id: context[:remote_post] && context[:remote_post].id,
      attrs: json_attrs(attrs)
    }

    insert =
      %PendingPost{user_id: user.id, video_id: video && video.id}
      |> PendingPost.changeset(params)
      |> Repo.insert()

    with {:ok, pending} <- insert do
      reserve_attachments(pending, user, attachments)
      broadcast_summary(pending)
      # A medium may have finished between the composer's check and this
      # insert; the publisher's claim makes a double publish impossible.
      maybe_publish(reload(pending))
      {:ok, pending}
    end
  end

  # The files this post now holds. Only the member's own, only rows nobody has
  # claimed — a stale or hostile id list can neither steal a file nor bring a
  # deleted one back.
  defp reserve_attachments(_pending, _user, []), do: :ok

  defp reserve_attachments(%PendingPost{} = pending, %User{id: user_id}, attachments) do
    ids = for %Attachment{id: id} <- attachments, do: id

    Repo.update_all(
      from(a in Attachment,
        where:
          a.id in ^ids and a.user_id == ^user_id and is_nil(a.post_id) and
            is_nil(a.message_id) and is_nil(a.pending_post_id)
      ),
      set: [pending_post_id: pending.id, updated_at: NaiveDateTime.utc_now(:second)]
    )

    :ok
  end

  # The map column round-trips through JSON: string keys, and nothing but what
  # JSON can carry.
  defp json_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Jason.encode!()
    |> Jason.decode!()
  end

  ## Reading

  @doc "One of the member's own waiting or finished rows, media preloaded."
  def get(%User{id: user_id}, id) do
    UUIDv7.with_cast(id, fn id ->
      from(p in PendingPost, where: p.id == ^id and p.user_id == ^user_id)
      |> Repo.one()
      |> preload_media()
    end)
  end

  @doc "The member's posts still waiting on their media, newest first."
  def waiting_for(%User{id: user_id}), do: waiting_for(user_id)

  def waiting_for(user_id) when is_binary(user_id) do
    from(p in PendingPost,
      where: p.user_id == ^user_id and p.status == "waiting",
      order_by: [desc: p.inserted_at]
    )
    |> Repo.all()
    |> preload_media()
  end

  @doc """
  Everything this member has parked here, newest first — what waits and what it
  became. The author's page at `/system/uploads` is the only reader.
  """
  def history_for(%User{id: user_id}, opts \\ []) do
    from(p in PendingPost,
      where: p.user_id == ^user_id,
      order_by: [desc: p.inserted_at],
      limit: ^Keyword.get(opts, :limit, @history_limit)
    )
    |> Repo.all()
    |> preload_media()
  end

  defp preload_media(nil), do: nil

  defp preload_media(pending_or_list),
    do: Repo.preload(pending_or_list, [:attachments, video: :frames])

  defp reload(%PendingPost{id: id}), do: preload_media(Repo.get!(PendingPost, id))

  @doc """
  The app bar's line: how many posts of this member's the **server** is still
  working on, and the percent of the one clip being converted (`nil` when
  nothing is converting).

  A row whose medium was refused is waiting for its *author*, not for us, so it
  is not counted: the chip is on every page and would otherwise sit there
  amber for ever while the card for that same row says it was refused.
  """
  def in_progress_summary(user_id) when is_binary(user_id) do
    rows = waiting_for(user_id)
    readings = readings(rows)
    working = Enum.filter(rows, &(readings[&1.id].state == :working))

    converting =
      for %PendingPost{video: %PostVideo{stage: "transcoding", progress: percent}} <- working,
          do: percent

    %{
      count: length(working),
      progress:
        case converting do
          [] -> nil
          list -> div(Enum.sum(list), length(list))
        end
    }
  end

  def in_progress_summary(_anonymous), do: %{count: 0, progress: nil}

  ## What it is waiting for

  @doc """
  What one row is waiting for, read once:

      %{stage: …, state: …, files: [%Attachment{}], file_states: %{id => …}}

  `stage` is where the pipeline is, as data a surface turns into a sentence —
  `{:video, video}`, `{:rendering, done, total}`, `{:checking, count}`,
  `:refused` or `:ready`. `state` is that classified for the publisher:
  `:ready`, `:refused` (it can never become ready, so the author has to
  choose) or `:working`. **Derived from the stage rather than read again**, so
  a new medium or a new stage word is one edit, not three.

  Surfaces take the whole map and pass it down; nothing asks twice.
  """
  def reading(%PendingPost{} = pending),
    do: pending |> List.wrap() |> readings() |> Map.fetch!(pending.id)

  @doc """
  The same for a list, by row id — **two queries for the whole list** rather
  than two per row, which is what keeps a page of waiting cards (and the app
  bar's chip, on every page) off a per-card round trip.
  """
  def readings(pendings) when is_list(pendings) do
    pendings = preload_media(pendings)
    ids = for pending <- pendings, file <- pending.attachments, do: file.id
    checking = page_counts(ids, "pending")
    rendered = page_counts(ids, :any)

    Map.new(pendings, &{&1.id, read_one(&1, checking, rendered)})
  end

  @doc "Whether this row can be published — `reading/1`'s `state`."
  def state(%PendingPost{} = pending), do: reading(pending).state

  @doc "Where the pipeline is with this row — `reading/1`'s `stage`."
  def stage(%PendingPost{} = pending), do: reading(pending).stage

  @doc "The files this row is waiting on, in upload order."
  def attachments(%PendingPost{} = pending), do: reading(pending).files

  defp read_one(%PendingPost{} = pending, checking, rendered) do
    files = Enum.sort_by(pending.attachments, & &1.inserted_at, NaiveDateTime)
    file_states = Map.new(files, &{&1.id, file_state(&1, checking)})
    stage = stage_of(pending.video, files, file_states, checking, rendered)

    %{
      stage: stage,
      state: state_of(stage),
      files: files,
      file_states: file_states,
      publishable_without_refused?: leftover?(pending, file_states)
    }
  end

  # Whether pressing "post it without the refused one" would actually publish
  # something. Two ways it would not, and both end on the same opaque "could
  # not be published" row, which tells the author nothing they can act on: the
  # refused file was everything the post had (the create path refuses an empty
  # post), or something that is *not* refused is still being worked on (a clip
  # that is not `ready` yet rolls the insert back). So the card offers the way
  # out only when it leads somewhere, and otherwise offers dropping the post
  # alone — the choice the author has either way.
  defp leftover?(%PendingPost{} = pending, file_states) do
    video = video_state(pending.video)
    states = Map.values(file_states)

    survivors_settled? = video in [:done, :refused] and Enum.all?(states, &(&1 != :working))

    # `video_state/1` answers `:done` for a post that has no clip at all, so
    # the clip only counts as content when there really is one.
    keeps_something? =
      body(pending) != nil or List.wrap(pending.attrs["image_ids"]) != [] or
        (pending.video != nil and video == :done) or :done in states

    survivors_settled? and keeps_something?
  end

  # The clip comes first when there is one, because it is the slowest and the
  # only stage that can name a percent.
  defp stage_of(video, files, file_states, checking, rendered) do
    video_state = video_state(video)
    still_checking = files |> Enum.map(&Map.get(checking, &1.id, 0)) |> Enum.sum()

    cond do
      video_state == :refused or :refused in Map.values(file_states) -> :refused
      video_state == :working -> {:video, video}
      Enum.any?(files, &(&1.stage in ~w(stored rendering))) -> rendering(files, rendered)
      still_checking > 0 -> {:checking, still_checking}
      true -> :ready
    end
  end

  defp rendering(files, rendered),
    do: {:rendering, page_sum(rendered, files), wanted_pages(files)}

  defp page_sum(counts, files),
    do: files |> Enum.map(&Map.get(counts, &1.id, 0)) |> Enum.sum()

  defp state_of(:refused), do: :refused
  defp state_of(:ready), do: :ready
  defp state_of(_working), do: :working

  defp page_counts([], _moderation), do: %{}

  defp page_counts(ids, moderation) do
    Image
    |> where([i], i.kind == ^Pages.kind() and i.attachment_id in ^ids)
    |> page_moderation(moderation)
    |> group_by([i], i.attachment_id)
    |> select([i], {i.attachment_id, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp page_moderation(query, :any), do: query
  defp page_moderation(query, moderation), do: where(query, [i], i.moderation == ^moderation)

  # How many pages the renders are aiming for, so "page 2 of 3" can be said.
  defp wanted_pages(files), do: files |> Enum.map(&Pages.wanted_count/1) |> Enum.sum()

  defp video_state(nil), do: :done

  defp video_state(%PostVideo{} = video) do
    cond do
      PostVideo.refused?(video) -> :refused
      PostVideo.ready?(video) -> :done
      true -> :working
    end
  end

  @doc """
  Whether one file is still being worked on, finished, or refused. **The one
  definition**, so the composer's chip, the waiting card's file row and the
  publisher cannot each answer it differently — a chip reading "ready" beside a
  post that then parks is exactly the confusion this whole issue is about.
  """
  def file_state(%Attachment{} = file), do: file_state(file, page_counts([file.id], "pending"))

  defp file_state(%Attachment{stage: stage} = file, checking) do
    cond do
      Attachment.refused?(file) -> :refused
      stage in ~w(stored rendering) -> :working
      Map.get(checking, file.id, 0) > 0 -> :working
      true -> :done
    end
  end

  @doc """
  Whether these files are all finished — rendered, and every preview page past
  the AI check. What the composer asks before deciding whether the post can go
  out now or has to wait.
  """
  def files_done?(files) when is_list(files) do
    checking = page_counts(Enum.map(files, & &1.id), "pending")
    Enum.all?(files, &(file_state(&1, checking) == :done))
  end

  ## The pipeline

  @doc """
  The rows the sweeper should look at, least-recently-looked-at first: waiting
  rows whose clock is due, and claims that have stood longer than any publish
  can take.
  """
  def due(limit) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now(:second)
    recheck = DateTime.add(now, -@recheck_seconds, :second)
    stale = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -@stale_after_seconds, :second)

    from(p in PendingPost,
      where:
        (p.status == "waiting" and (is_nil(p.checked_at) or p.checked_at < ^recheck)) or
          (p.status == "publishing" and p.updated_at < ^stale),
      order_by: [asc_nulls_first: p.checked_at, asc: p.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  One pass: publishes every due row whose media are done, resumes every claim a
  dead slot left behind, and stamps the clock on the rest. Answers how many
  rows it looked at.
  """
  def sweep(limit \\ 20) do
    due = due(limit)
    Enum.each(due, &work/1)
    length(due)
  end

  defp work(%PendingPost{status: "publishing"} = pending), do: resume(pending)

  defp work(%PendingPost{status: "waiting"} = pending) do
    case state(pending) do
      :ready -> Publisher.publish(pending)
      _working_or_refused -> touch(pending)
    end
  end

  defp work(%PendingPost{}), do: :ok

  # A claim nobody finished. If the post is already there, the slot died
  # between the insert and the bookkeeping and the only thing left is to say
  # so; otherwise the claim is released and the row published from the top,
  # under the very same id.
  defp resume(%PendingPost{minted_post_id: id} = pending) when is_binary(id) do
    case Repo.get(Post, id) do
      %Post{} = post -> Publisher.finish_published(pending, post)
      nil -> release_and_publish(pending)
    end
  end

  defp resume(%PendingPost{} = pending), do: release_and_publish(pending)

  defp release_and_publish(%PendingPost{} = pending) do
    # Compare-and-set on the heartbeat the claim wrote, so the slot that is
    # merely slow rather than dead cannot have its row taken out from under it.
    {count, _} =
      from(p in PendingPost,
        where:
          p.id == ^pending.id and p.status == "publishing" and
            p.updated_at == ^pending.updated_at
      )
      |> Repo.update_all(set: [status: "waiting", updated_at: NaiveDateTime.utc_now(:second)])

    if count == 1, do: work(reload(pending)), else: :taken
  end

  # The clock, on the outcome where nothing could be done. It is the
  # *scheduler's* clock, not a claim that the work happened.
  defp touch(%PendingPost{} = pending) do
    Repo.update_all(from(p in PendingPost, where: p.id == ^pending.id),
      set: [checked_at: DateTime.utc_now(:second)]
    )

    :ok
  end

  ## Nudges from the media pipelines

  @doc """
  A medium of this member's moved: publish every waiting post that was only
  waiting for it. Called from the places that settle a clip, a file's render
  and a preview page's verdict, so the post appears the second it can rather
  than at the sweeper's next pass.
  """
  def media_changed(:video, video_id) when is_binary(video_id),
    do: publish_all(from(p in PendingPost, where: p.video_id == ^video_id))

  def media_changed(:attachment, attachment_id) when is_binary(attachment_id) do
    publish_all(
      from(p in PendingPost,
        join: a in Attachment,
        on: a.pending_post_id == p.id,
        where: a.id == ^attachment_id
      )
    )
  end

  def media_changed(_kind, nil), do: :ok

  # Answers the last row's outcome, which is what a nudge with exactly one
  # waiting row behind it — the ordinary case — wants to hand back.
  defp publish_all(query) do
    query
    |> where([p], p.status == "waiting")
    |> Repo.all()
    |> preload_media()
    |> Enum.reduce(:ok, fn pending, _previous -> maybe_publish(pending) end)
  end

  defp maybe_publish(%PendingPost{} = pending) do
    if state(pending) == :ready, do: Publisher.publish(pending), else: :ok
  end

  ## The author's two ways out

  @doc "Drops a waiting post and the media it holds, files and bytes and all."
  def cancel(%PendingPost{status: "waiting"} = pending) do
    {count, _} =
      from(p in PendingPost, where: p.id == ^pending.id and p.status == "waiting")
      |> Repo.update_all(set: [status: "canceled"])

    if count == 1 do
      pending = reload(pending)
      if pending.video, do: Videos.delete_pending_video(pending.video)
      Enum.each(pending.attachments, &Attachments.delete_pending/1)

      broadcast(pending.user_id, {:pending_post, %{summary(pending) | status: "canceled"}})
    end

    :ok
  end

  def cancel(%PendingPost{}), do: :ok

  @doc """
  Publishes the waiting text as it is, without whatever was refused — the
  clip, the files, or both. Those go with their bytes.
  """
  def publish_without_refused(%PendingPost{status: "waiting"} = pending),
    do: Publisher.publish(pending, without_refused: true)

  def publish_without_refused(%PendingPost{}), do: {:error, :not_waiting}

  @doc """
  The text a parked row was written with. The attrs are a JSON column, so this
  is the one place that reaches into it — the author's page and the waiting
  card both ask here rather than each knowing the key.
  """
  def body(%PendingPost{attrs: %{"body" => body}}) when is_binary(body) and body != "", do: body
  def body(%PendingPost{}), do: nil
end
