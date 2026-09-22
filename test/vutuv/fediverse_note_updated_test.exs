defmodule Vutuv.FediverseNoteUpdatedTest do
  @moduledoc """
  An edit reaches Mastodon only when the Note names when it changed (see
  docs/architecture/fediverse.md, "Post lifecycle").
  """

  use Vutuv.DataCase

  alias Vutuv.Posts
  alias Vutuv.Repo
  alias VutuvWeb.Fediverse.Docs

  setup do
    user = insert_activated_user(fediverse_followers?: true)
    {:ok, post} = Posts.create_post(user, %{body: "Hello"})
    %{user: user, post: Repo.preload(post, Docs.note_preloads())}
  end

  defp edited(post), do: %{post | updated_at: NaiveDateTime.add(post.inserted_at, 300)}

  # The wire format pinned on its own terms, not borrowed from the module.
  defp stamp(at),
    do: at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601() |> Kernel.<>("Z")

  # A late picture moves no `updated_at`, so the stamp is the build time: an
  # Update after an edit must still read as newer than the edit's own.
  test "an Update names the moment it was built, and its id carries it", %{user: user, post: post} do
    earliest = stamp(NaiveDateTime.utc_now())
    activity = Docs.update_activity(edited(post), user)
    latest = stamp(NaiveDateTime.utc_now())

    updated = activity["object"]["updated"]
    assert earliest <= updated and updated <= latest
    assert String.ends_with?(activity["id"], "#update-" <> updated)
  end

  test "a fresh post's Note carries no updated", %{user: user, post: post} do
    refute Map.has_key?(Docs.note(post, user), "updated")
  end

  test "an edited post's Note carries updated when fetched", %{user: user, post: post} do
    post = edited(post)

    assert Docs.note(post, user)["updated"] == stamp(post.updated_at)
  end
end
