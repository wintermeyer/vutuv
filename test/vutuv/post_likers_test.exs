defmodule Vutuv.PostLikersTest do
  @moduledoc """
  Who a post's likes are attributed to (issue #1233): `Vutuv.Posts.post_likers/2`
  and the `:like_attribution?` preference behind it.

  async: false — several tests inject installation defaults into the
  node-global `Vutuv.Prefs.Cache` (`:persistent_term`), which every other test
  rendering a post would read.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Prefs
  alias Vutuv.Prefs.Cache

  defp with_installation_defaults(overrides) do
    Cache.store(Map.merge(Prefs.shipped_defaults(), overrides))
    on_exit(&Cache.clear/0)
  end

  defp liker_ids(post, opts \\ []) do
    post.id |> Posts.post_likers(opts) |> Enum.map(& &1.id)
  end

  setup do
    author = insert_activated_user(first_name: "Auto", last_name: "Author")
    post = create_post!(author, %{body: "Who liked this?"})

    %{author: author, post: post}
  end

  describe "post_likers/2" do
    test "names a member who allows attribution", %{post: post} do
      fan = insert_activated_user(first_name: "Fanny", last_name: "Fan")
      :ok = Posts.like_post(fan, post)

      assert liker_ids(post) == [fan.id]
    end

    test "leaves out a member who opted out — but the count still includes them", %{post: post} do
      shy = insert_activated_user(like_attribution?: false)
      loud = insert_activated_user()
      :ok = Posts.like_post(shy, post)
      :ok = Posts.like_post(loud, post)

      assert liker_ids(post) == [loud.id]

      # The whole point of the opt-out: it hides WHO you are, never THAT the
      # post was liked. A private choice must not shrink somebody else's tally.
      assert Posts.engagement_counts(post.id).likes == 2
      assert Posts.shown_counts(Posts.engagement_counts(post.id)).likes == 2
    end

    test "shows the opted-out liker to the post's author", %{post: post} do
      shy = insert_activated_user(like_attribution?: false)
      :ok = Posts.like_post(shy, post)

      assert liker_ids(post) == []
      assert liker_ids(post, include_hidden?: true) == [shy.id]
    end

    test "is newest first and capped", %{post: post} do
      fans =
        for _i <- 1..(Posts.likers_shown() + 2) do
          fan = insert_activated_user()
          :ok = Posts.like_post(fan, post)
          fan
        end

      ids = liker_ids(post)

      assert length(ids) == Posts.likers_shown()
      assert ids == fans |> Enum.reverse() |> Enum.take(Posts.likers_shown()) |> Enum.map(& &1.id)
    end

    test "leaves out a member whose account is hidden", %{post: post} do
      gone = insert_activated_user(deactivated_at: DateTime.utc_now(:second))
      :ok = Posts.like_post(gone, post)

      assert liker_ids(post) == []
      # Their like still counts; they simply have no face to show.
      assert Posts.engagement_counts(post.id).likes == 1
    end
  end

  describe "a page's like (issue #1410)" do
    test "a page is listed beside the members, newest first", %{post: post} do
      fan = insert_activated_user()
      :ok = Posts.like_post(fan, post)
      page = insert(:organization)
      page_like!(post, page)

      assert liker_ids(post) == [page.id, fan.id]
    end

    test "a frozen page keeps its count but loses its face", %{post: post} do
      page = insert(:organization, frozen_at: NaiveDateTime.utc_now(:second))
      page_like!(post, page)

      # The #1408 shape — see the per-kind gate in `Posts.post_likers/2`.
      assert liker_ids(post) == []
      assert Posts.engagement_counts(post.id).likes == 1
    end

    test "a page that is not active has no face either", %{post: post} do
      page = insert(:organization, status: "pending", verified_at: nil)
      page_like!(post, page)

      assert liker_ids(post) == []
    end

    test "a page has no attribution preference and is always named", %{post: post} do
      with_installation_defaults(%{like_attribution?: false})

      untouched = insert_activated_user()
      :ok = Posts.like_post(untouched, post)
      page = insert(:organization)
      page_like!(post, page)

      # The member inherits the installation's opt-out; the page must not —
      # see the page exemption in `scope_attributed/2`.
      assert liker_ids(post) == [page.id]
    end
  end

  describe "the preference resolves through all three layers" do
    test "the shipped default attributes a member who never touched it", %{post: post} do
      assert Prefs.shipped_defaults()[:like_attribution?] == true

      fan = insert_activated_user()
      assert fan.like_attribution? == nil
      :ok = Posts.like_post(fan, post)

      assert liker_ids(post) == [fan.id]
    end

    test "an installation default of false hides every untouched member", %{post: post} do
      with_installation_defaults(%{like_attribution?: false})

      fan = insert_activated_user()
      :ok = Posts.like_post(fan, post)

      assert Prefs.get(fan, :like_attribution?) == false
      assert liker_ids(post) == []
    end

    test "a member's own choice beats the installation default", %{post: post} do
      with_installation_defaults(%{like_attribution?: false})

      opted_in = insert_activated_user(like_attribution?: true)
      untouched = insert_activated_user()
      :ok = Posts.like_post(opted_in, post)
      :ok = Posts.like_post(untouched, post)

      assert Prefs.get(opted_in, :like_attribution?) == true
      assert Prefs.get(untouched, :like_attribution?) == false
      assert liker_ids(post) == [opted_in.id]
    end
  end
end
