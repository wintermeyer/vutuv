defmodule Vutuv.Posts.PendingVideoPost do
  @moduledoc """
  A post that waits for its clip (issue #1910).

  A photo post publishes at once and its picture catches up; a text whose
  video is missing reads as broken, so a post with a clip is not a post until
  the clip is ready. Rather than a hidden `posts` row — which every feed,
  profile and archive query would have to learn to filter — the composer's
  submission is stored here as a job: the create path it took (`kind`), the
  context that path needs, and the attrs verbatim. `Vutuv.Videos.Publisher`
  turns the row into a real post through the very `Vutuv.Posts.create_*`
  function the composer would have called, the moment the clip is ready.

  A refused or broken clip does not lose the text: the row stays `waiting`
  with the video's verdict on it, and the author's feed card offers to publish
  without the video or to drop the whole thing.
  """

  use VutuvWeb, :model

  @kinds ~w(post reply organization_post remote_reply remote_post_reply)

  schema "pending_video_posts" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:video, Vutuv.Posts.PostVideo)

    field(:kind, :string)
    belongs_to(:parent_post, Vutuv.Posts.Post)
    belongs_to(:organization, Vutuv.Organizations.Organization)
    belongs_to(:note, Vutuv.Fediverse.Note)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)

    field(:attrs, :map, default: %{})

    field(:status, :string, default: "waiting")
    belongs_to(:post, Vutuv.Posts.Post)
    field(:error, :string)

    timestamps()
  end

  def changeset(pending, params) do
    pending
    |> cast(params, [:kind, :parent_post_id, :organization_id, :note_id, :remote_post_id, :attrs])
    |> validate_required([:kind, :attrs])
    |> validate_inclusion(:kind, @kinds)
  end
end
