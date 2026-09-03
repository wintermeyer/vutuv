defmodule Vutuv.Videos.Publisher do
  @moduledoc """
  Turns a `Vutuv.Posts.PendingVideoPost` into the post it was written as
  (issue #1910), through the very create path the composer would have taken
  (`Vutuv.Posts.create_in_context/4`) — so a reply is a reply, an
  organization post is an organization post, and an answer to another network
  carries its sidecar.

  `publish/2` is claimed by a compare-and-set on the row's status, so the two
  callers that can race (the job finishing the H.264 file and the last frame
  verdict landing) cannot publish the same text twice. A refused clip never
  gets here on its own: the row waits with the verdict shown until the author
  chooses to publish without the video (`without_video: true`) or to drop it.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Posts.PendingVideoPost
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostVideo
  alias Vutuv.Repo
  alias Vutuv.Videos

  @doc "Publishes every post waiting on `video`."
  def publish_for(%PostVideo{id: video_id}) do
    from(p in PendingVideoPost, where: p.video_id == ^video_id and p.status == "waiting")
    |> Repo.all()
    |> Enum.each(&publish/1)
  end

  @doc """
  Publishes one waiting row. `{:ok, post}` once it is a post, `{:error,
  reason}` when the create path refused (the row records the reason and
  stays visible as failed), `:taken` when another process got there first.
  """
  def publish(%PendingVideoPost{} = pending, opts \\ []) do
    {count, _} =
      from(p in PendingVideoPost, where: p.id == ^pending.id and p.status == "waiting")
      |> Repo.update_all(set: [status: "publishing"])

    if count == 1, do: publish_claimed(pending, opts), else: :taken
  end

  defp publish_claimed(pending, opts) do
    without_video? = Keyword.get(opts, :without_video, false)

    result =
      with %User{} = author <- Repo.get(User, pending.user_id) || {:error, :author_gone},
           {:ok, context} <- context(pending) do
        Posts.create_in_context(author, pending.kind, context, attrs(pending, without_video?))
      end

    case result do
      {:ok, post} ->
        finish(pending, "published", post_id: post.id)
        if without_video?, do: drop_video(pending)
        {:ok, post}

      {:error, reason} ->
        Logger.warning(
          "pending_video_post failed pending=#{pending.id} reason=#{inspect(reason)}"
        )

        finish(pending, "failed", error: String.slice(inspect(reason), 0, 2_000))
        {:error, reason}
    end
  end

  defp attrs(pending, without_video?) do
    if without_video? or pending.video_id == nil,
      do: Map.delete(pending.attrs, "video_id"),
      else: Map.put(pending.attrs, "video_id", pending.video_id)
  end

  # The text went out without it: the clip and its files go.
  defp drop_video(%PendingVideoPost{video_id: nil}), do: :ok

  defp drop_video(%PendingVideoPost{video_id: video_id}) do
    case Videos.get_video(video_id) do
      nil -> :ok
      video -> Videos.delete_pending_video(video)
    end
  end

  defp finish(pending, status, changes) do
    {:ok, updated} =
      pending
      |> Ecto.Changeset.change([status: status] ++ changes)
      |> Repo.update()

    Videos.broadcast(updated.user_id, {:pending_video_post, Videos.pending_summary(updated)})
    updated
  end

  # The rows the create path needs, by the id the pending row kept. A context
  # that is gone meanwhile (a deleted parent, a swept note) is a failure with
  # a name, never a post in the wrong place.
  defp context(%PendingVideoPost{kind: "post"}), do: {:ok, %{}}

  defp context(%PendingVideoPost{kind: "reply", parent_post_id: id}),
    do: fetch_context(Post, id, :parent, :parent_gone)

  defp context(%PendingVideoPost{kind: "organization_post", organization_id: id}),
    do: fetch_context(Organization, id, :organization, :organization_gone)

  defp context(%PendingVideoPost{kind: "remote_reply", note_id: id}),
    do: fetch_context(Note, id, :note, :note_gone)

  defp context(%PendingVideoPost{kind: "remote_post_reply", remote_post_id: id}),
    do: fetch_context(RemotePost, id, :remote_post, :remote_post_gone)

  defp fetch_context(schema, id, key, gone) do
    case id && Repo.get(schema, id) do
      nil -> {:error, gone}
      record -> {:ok, %{key => record}}
    end
  end
end
