defmodule Vutuv.FeedLanguageFilterTest do
  @moduledoc """
  The feed's chosen-languages filter (issue #1461): "hide" drops posts in
  other languages from every feed source, NULL (undeclared) never hides, and
  the shipped default ("original") filters nothing.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts

  defp reader!(attrs) do
    :activated_user
    |> insert()
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp author_followed_by!(reader) do
    author = insert(:activated_user)
    insert(:follow, follower: reader, followee: author)
    author
  end

  defp post!(author, body, language) do
    {:ok, post} = Posts.create_post(author, %{body: body, language: language})
    post
  end

  defp feed_ids(reader) do
    Posts.feed_page(reader).entries |> Enum.map(& &1.post.id) |> MapSet.new()
  end

  test "hide drops foreign-language posts; chosen and NULL always show" do
    reader = reader!(%{feed_foreign_posts: "hide", feed_languages: ["de"]})
    author = author_followed_by!(reader)

    german = post!(author, "Guten Morgen.", "de")
    english = post!(author, "Good morning.", "en")
    {:ok, undeclared} = Posts.create_post(author, %{body: "Ohne Sprache."})

    ids = feed_ids(reader)
    assert german.id in ids
    assert undeclared.id in ids
    refute english.id in ids
  end

  test "the shipped default filters nothing" do
    reader = reader!(%{feed_languages: ["de"]})
    author = author_followed_by!(reader)
    english = post!(author, "Good morning.", "en")

    assert english.id in feed_ids(reader)
  end

  test "hide with no chosen languages filters nothing" do
    reader = reader!(%{feed_foreign_posts: "hide", feed_languages: nil})
    author = author_followed_by!(reader)
    english = post!(author, "Good morning.", "en")

    assert english.id in feed_ids(reader)
  end

  test "hide reaches the remote-post source too" do
    reader = reader!(%{feed_foreign_posts: "hide", feed_languages: ["de"]})

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/them#{System.unique_integer([:positive])}",
        host: "social.example",
        handle: "them",
        inbox_uri: "https://social.example/inbox"
      })

    Repo.insert!(%Follow{
      user_id: reader.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://social.example/follows/#{System.unique_integer([:positive])}"
    })

    now = DateTime.utc_now(:second)

    for language <- ["en", "de", nil] do
      Repo.insert!(%RemotePost{
        remote_account_id: account.id,
        object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
        content_text: "Text #{language}",
        language: language,
        audience: "public",
        kind: "note",
        published_at: now,
        received_at: now,
        expires_at: DateTime.add(now, 86_400)
      })
    end

    remote_languages =
      Posts.feed_page(reader).entries
      |> Enum.filter(&Posts.remote_feed_entry?/1)
      |> Enum.map(& &1.remote_post.language)

    assert "de" in remote_languages
    assert nil in remote_languages
    refute "en" in remote_languages
  end

  test "the changeset stores only known codes and maps all-or-none to nil" do
    user = insert(:user)

    {:ok, updated} =
      Vutuv.Accounts.update_user(user, %{"feed_languages" => ["de", "xx", "<script>"]})

    assert updated.feed_languages == ["de"]

    {:ok, cleared} = Vutuv.Accounts.update_user(updated, %{"feed_languages" => []})
    assert cleared.feed_languages == nil

    {:ok, all} =
      Vutuv.Accounts.update_user(updated, %{"feed_languages" => Vutuv.Languages.codes()})

    assert all.feed_languages == nil
  end
end
