defmodule Vutuv.Posts.Publisher do
  @moduledoc """
  Turns a `Vutuv.Posts.PendingPost` into the post it was written as (issues
  #1910, #2106), through the very create path the composer would have taken
  (`Vutuv.Posts.create_in_context/4`) — so a reply is a reply, an organization
  post is an organization post, and an answer to another network carries its
  sidecar.

  ## The claim, and why it mints an id

  `publish/2` is claimed by a compare-and-set on the row's status, so the
  callers that can race (a clip finishing, a file's last preview page clearing
  the AI check, the sweeper coming round) cannot publish the same text twice.
  The claim also writes `minted_post_id`: the id the post is about to get.
  Ecto would otherwise mint it inside the insert, and a slot killed between
  that insert and the bookkeeping would leave a row that looks unpublished
  beside a post that exists — which a resume would answer by writing the
  member's post a second time. With the id on the row first, the resume asks
  whether that post is already there (`Vutuv.Posts.Pending.sweep/1`).

  A refused medium never gets here on its own: the row waits with the verdict
  shown until the author chooses to publish without it (`without_refused:
  true`) or to drop the whole thing.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Accounts.User
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Posts.Pending
  alias Vutuv.Posts.PendingPost
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostVideo
  alias Vutuv.Repo
  alias Vutuv.UUIDv7
  alias Vutuv.Videos

  @doc """
  Publishes one waiting row. `{:ok, post}` once it is a post, `{:error,
  reason}` when the create path refused (the row records the reason and stays
  visible as failed), `:taken` when another process got there first.

  `without_refused: true` publishes the text without whatever was refused —
  the clip, the files, or both — and those go with their bytes.
  """
  def publish(%PendingPost{} = pending, opts \\ []) do
    minted = pending.minted_post_id || UUIDv7.generate()

    {count, _} =
      from(p in PendingPost, where: p.id == ^pending.id and p.status == "waiting")
      |> Repo.update_all(
        set: [
          status: "publishing",
          minted_post_id: minted,
          checked_at: DateTime.utc_now(:second),
          updated_at: NaiveDateTime.utc_now(:second)
        ]
      )

    if count == 1,
      do: publish_claimed(%{pending | minted_post_id: minted}, opts),
      else: :taken
  end

  @doc """
  Finishes a row whose post is already there — what the resume does for a slot
  killed between the insert and the bookkeeping. No create path runs.
  """
  def finish_published(%PendingPost{} = pending, %Post{} = post) do
    finish(pending, "published", post_id: post.id)
    {:ok, post}
  end

  defp publish_claimed(pending, opts) do
    without_refused? = Keyword.get(opts, :without_refused, false)
    media = media(pending, without_refused?)

    result =
      with %User{} = author <- Repo.get(User, pending.user_id) || {:error, :author_gone},
           {:ok, context} <- context(pending) do
        Posts.create_in_context(author, pending.kind, context, attrs(pending, media))
      end

    case result do
      {:ok, post} ->
        finish(pending, "published", post_id: post.id)
        drop_refused(pending, without_refused?)
        {:ok, post}

      {:error, reason} ->
        Logger.warning("pending_post failed pending=#{pending.id} reason=#{inspect(reason)}")

        finish(pending, "failed", error: String.slice(inspect(reason), 0, 2_000))
        {:error, reason}
    end
  end

  # What this post takes with it: the clip unless it was refused (or is gone),
  # and the files that were not.
  defp media(pending, without_refused?) do
    video = video_of(pending)
    files = Attachments.for_pending_post(pending)

    %{
      video_id: if(usable_video?(video, without_refused?), do: video.id),
      attachment_ids: for(a <- files, usable_file?(a, without_refused?), do: a.id)
    }
  end

  defp video_of(%PendingPost{video_id: nil}), do: nil
  defp video_of(%PendingPost{video_id: id}), do: Videos.get_video(id)

  defp usable_video?(nil, _without_refused?), do: false
  defp usable_video?(%PostVideo{} = video, true), do: not PostVideo.refused?(video)
  defp usable_video?(%PostVideo{}, false), do: true

  defp usable_file?(%Attachment{} = file, true), do: not Attachment.refused?(file)
  defp usable_file?(%Attachment{}, false), do: true

  # The attrs the create path gets: what the composer wrote, plus the id this
  # publish minted and the media that survived.
  # An **atom** key for the minted id beside the composer's string ones, which
  # is what keeps it out of reach of anything a request can send — see
  # `put_minted_id/2` in `Vutuv.Posts`.
  defp attrs(pending, media) do
    pending.attrs
    |> Map.put(:minted_post_id, pending.minted_post_id)
    |> put_or_delete("video_id", media.video_id)
    |> Map.put("attachment_ids", media.attachment_ids)
  end

  defp put_or_delete(attrs, key, nil), do: Map.delete(attrs, key)
  defp put_or_delete(attrs, key, value), do: Map.put(attrs, key, value)

  # The text went out without them: the refused clip and the refused files go
  # with their bytes. Only on the author's explicit "post it without them" —
  # an ordinary publish takes everything it named.
  defp drop_refused(_pending, false), do: :ok

  defp drop_refused(pending, true) do
    case video_of(pending) do
      %PostVideo{} = video ->
        if PostVideo.refused?(video), do: Videos.delete_pending_video(video)

      nil ->
        :ok
    end

    pending
    |> Attachments.for_pending_post()
    |> Enum.filter(&Attachment.refused?/1)
    |> Enum.each(&Attachments.delete_pending/1)
  end

  defp finish(pending, status, changes) do
    {:ok, updated} =
      pending
      |> Ecto.Changeset.change([status: status] ++ changes)
      |> Repo.update()

    Pending.broadcast_summary(updated)
    updated
  end

  # The rows the create path needs, by the id the pending row kept. A context
  # that is gone meanwhile (a deleted parent, a swept note) is a failure with
  # a name, never a post in the wrong place.
  defp context(%PendingPost{kind: "post"}), do: {:ok, %{}}

  defp context(%PendingPost{kind: "reply", parent_post_id: id}),
    do: fetch_context(Post, id, :parent, :parent_gone)

  defp context(%PendingPost{kind: "organization_post", organization_id: id}),
    do: fetch_context(Organization, id, :organization, :organization_gone)

  defp context(%PendingPost{kind: "remote_reply", note_id: id}),
    do: fetch_context(Note, id, :note, :note_gone)

  defp context(%PendingPost{kind: "remote_post_reply", remote_post_id: id}),
    do: fetch_context(RemotePost, id, :remote_post, :remote_post_gone)

  defp fetch_context(schema, id, key, gone) do
    case id && Repo.get(schema, id) do
      nil -> {:error, gone}
      record -> {:ok, %{key => record}}
    end
  end
end
