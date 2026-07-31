defmodule Vutuv.Tags.TimelineFediverseDisabledTest do
  @moduledoc """
  The tag timeline on an installation with the fediverse switched off — an
  intranet install, or any operator who wants no outside content on their tag
  pages.

  **`async: false`, and it has to be**: the switch is `:fediverse_enabled` in
  the application env, which the SQL sandbox does not roll back and every other
  test process can read. An async module flipping it would take the fediverse
  away from whatever else happens to run at that moment.
  """
  use Vutuv.DataCase, async: false
  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse.Hashtags
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Tags.Timeline

  setup do
    Application.put_env(:vutuv, :fediverse_enabled, false)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)
    :ok
  end

  test "has no fediverse half at all" do
    tag = insert(:tag, name: "Offline-#{System.unique_integer([:positive])}")
    author = insert(:activated_user)
    mine = create_post!(author, %{body: "Von hier", tags: tag.name})

    # A cached post that IS filed under the tag: it is the switch that keeps it
    # off the page, not an absence of data. Filing still works, since a follow
    # that predates the switch leaves rows behind.
    now = DateTime.utc_now(:second)

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/them",
        host: "social.example",
        handle: "them",
        inbox_uri: "https://social.example/inbox"
      })

    theirs =
      Repo.insert!(%RemotePost{
        remote_account_id: account.id,
        object_uri: "https://social.example/posts/1",
        content_text: "Von woanders",
        audience: "public",
        kind: "note",
        published_at: now,
        received_at: now,
        expires_at: DateTime.add(now, 86_400)
      })

    Hashtags.sync(theirs, %{"tag" => [%{"type" => "Hashtag", "name" => "#" <> tag.name}]})

    assert %{entries: [%{post: post}], total: 1} = Timeline.page(tag)
    assert post.id == mine.id

    assert %{entries: [], total: 0} = Timeline.page(tag, source: :fediverse)
  end
end
