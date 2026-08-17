defmodule Vutuv.FediverseLanguageTest do
  @moduledoc """
  The post language on the wire (issue #1488): outbound as AS2 `contentMap`
  keyed by the author's declaration (a NULL-language post emits NO key —
  never a fabricated tag), inbound read through the one `as2_language/1`
  (contentMap → nameMap → summaryMap → @context @language) and stored on the
  cached rows. `async: false` — the inbound caps live in the shared
  `Vutuv.RateLimiter` ETS table.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias VutuvWeb.Fediverse.Docs

  @actor "https://social.example/users/them"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  describe "outbound: Docs.note/2" do
    test "a declared language federates as contentMap" do
      user = insert(:activated_user)
      {:ok, post} = Posts.create_post(user, %{body: "Guten Morgen.", language: "de"})
      post = Posts.get_post(post.id)

      note = Docs.note(post, user)

      assert %{"de" => html} = note["contentMap"]
      assert html == note["content"]
    end

    test "a NULL-language post yields a Note without a contentMap key" do
      user = insert(:activated_user)
      {:ok, post} = Posts.create_post(user, %{body: "Ohne Sprache."})
      post = Posts.get_post(post.id)

      note = Docs.note(post, user)

      refute Map.has_key?(note, "contentMap")
    end
  end

  describe "as2_language/1" do
    test "reads the maps in Mastodon's order and normalizes the tag" do
      assert Fediverse.as2_language(%{"contentMap" => %{"en-US" => "x"}}) == "en"
      assert Fediverse.as2_language(%{"nameMap" => %{"fr" => "x"}}) == "fr"
      assert Fediverse.as2_language(%{"summaryMap" => %{"DE" => "x"}}) == "de"

      assert Fediverse.as2_language(%{
               "@context" => ["https://www.w3.org/ns/activitystreams", %{"@language" => "es"}]
             }) == "es"

      # contentMap wins over the fallbacks.
      assert Fediverse.as2_language(%{
               "contentMap" => %{"de" => "x"},
               "nameMap" => %{"en" => "y"}
             }) == "de"
    end

    test "absent or hostile declarations store nothing" do
      assert Fediverse.as2_language(%{}) == nil
      assert Fediverse.as2_language(%{"contentMap" => %{}}) == nil
      assert Fediverse.as2_language(%{"contentMap" => %{"<script>" => "x"}}) == nil
      assert Fediverse.as2_language(nil) == nil
    end

    # Mastodon's own picker offers tags this installation has no chip for.
    # Stored, such a code would be hidden from every hide-mode reader with no
    # way to tick it back; NULL is always shown (issue #1535).
    test "a well-formed tag outside the curated list stores nothing" do
      assert Fediverse.as2_language(%{"contentMap" => %{"eo" => "x"}}) == nil
      assert Fediverse.as2_language(%{"contentMap" => %{"tok" => "x"}}) == nil
      assert Fediverse.as2_language(%{"contentMap" => %{"nb" => "x"}}) == nil
    end
  end

  describe "inbound storage" do
    defp followed_account do
      account =
        Repo.insert!(%RemoteAccount{
          actor_uri: @actor,
          host: "social.example",
          handle: "them",
          inbox_uri: @actor <> "/inbox"
        })

      user = insert(:activated_user, fediverse_followers?: true)

      Repo.insert!(%Follow{
        user_id: user.id,
        remote_account_id: account.id,
        state: "accepted",
        follow_activity_id: "https://vutuv.test/follows/#{account.id}"
      })

      {user, account}
    end

    defp create_activity(object_overrides) do
      object =
        Map.merge(
          %{
            "id" => "https://social.example/posts/#{System.unique_integer([:positive])}",
            "type" => "Note",
            "attributedTo" => @actor,
            "content" => "<p>Hello.</p>",
            "to" => [@public],
            "cc" => []
          },
          object_overrides
        )

      %{"type" => "Create", "actor" => @actor, "object" => object}
    end

    test "a cached remote post keeps the language its origin declared" do
      {_user, _account} = followed_account()

      activity = create_activity(%{"contentMap" => %{"en" => "<p>Hello.</p>"}})
      assert :ok = Fediverse.record_remote_post(activity, @actor)

      assert [%RemotePost{language: "en"}] = Repo.all(RemotePost)
    end

    test "a post that declares nothing stores NULL" do
      {_user, _account} = followed_account()

      assert :ok = Fediverse.record_remote_post(create_activity(%{}), @actor)

      assert [%RemotePost{language: nil}] = Repo.all(RemotePost)
    end
  end
end
