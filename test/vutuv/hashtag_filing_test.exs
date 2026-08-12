defmodule Vutuv.HashtagFilingTest do
  @moduledoc """
  Filing a post under the tags its `#hashtags` name, on both sides of the fence:
  a member's post body (`Vutuv.Posts.PostHashtag`) and a cached remote post
  (`Vutuv.Fediverse.Hashtags`).

  The rule both sides share is that ingestion **mints nothing**: an unknown
  hashtag files nothing and leaves no tag page behind.
  """
  use Vutuv.DataCase

  alias Vutuv.Fediverse.Hashtags
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Fediverse.RemotePostTag
  alias Vutuv.Mentions
  alias Vutuv.Posts
  alias Vutuv.Posts.PostHashtag
  alias Vutuv.Tags

  defp confirmed_user, do: insert(:user, email_confirmed?: true)

  # A tag whose slug is a valid hashtag. The factory's `unique_tag_name/1`
  # separates with a hyphen, which the `#hashtag` grammar (`[A-Za-z0-9_]+`) ends
  # the tag at — so `#berlin-7` would name the tag `berlin`, not this one.
  defp tag_named(base) do
    name = "#{base}_#{System.unique_integer([:positive])}"
    insert(:tag, name: name, slug: Vutuv.SlugHelpers.tagify(name))
  end

  defp filed_tag_ids(%Vutuv.Posts.Post{} = post) do
    Repo.all(from(ph in PostHashtag, where: ph.post_id == ^post.id, select: ph.tag_id))
  end

  defp filed_tag_ids(%RemotePost{} = post) do
    Repo.all(from(pt in RemotePostTag, where: pt.remote_post_id == ^post.id, select: pt.tag_id))
  end

  defp remote_post(text) do
    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/them-#{System.unique_integer([:positive])}",
        host: "social.example",
        handle: "them",
        inbox_uri: "https://social.example/inbox"
      })

    now = DateTime.utc_now(:second)

    Repo.insert!(%RemotePost{
      remote_account_id: account.id,
      object_uri: "https://social.example/posts/#{System.unique_integer([:positive])}",
      content_text: text,
      audience: "public",
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  describe "Mentions.hashtags/1" do
    test "reads the same hashtags the renderer links, and skips code" do
      assert Mentions.hashtags("Hello #Berlin and #elixir_lang!") == ["berlin", "elixir_lang"]
      assert Mentions.hashtags("a `#nope` span and\n```\n#alsonope\n```\n#yes") == ["yes"]
      assert Mentions.hashtags("see /page#fragment or &#39;") == []
      assert Mentions.hashtags("@handle only") == []
      assert Mentions.hashtags(nil) == []
    end

    test "an escaped underscore still names the tag the renderer links" do
      # Milkdown escapes `_` inside a hashtag run; the renderer sees through it,
      # so the filing must too or a post is filed under the wrong tag.
      assert Mentions.hashtags("about #elixir\\_lang") == ["elixir_lang"]
    end
  end

  describe "a member's post body" do
    test "is filed under an existing tag its hashtag names" do
      user = confirmed_user()
      tag = tag_named("berlin")

      {:ok, post} = Posts.create_post(user, %{body: "Moving to ##{tag.slug} next week."})

      assert filed_tag_ids(post) == [tag.id]
    end

    test "files nothing for an unknown hashtag and mints no tag" do
      user = confirmed_user()
      unknown = "nosuchtag_#{System.unique_integer([:positive])}"

      {:ok, post} = Posts.create_post(user, %{body: "About ##{unknown}."})

      assert filed_tag_ids(post) == []
      refute Repo.exists?(from(t in Vutuv.Tags.Tag, where: t.slug == ^unknown))
    end

    test "does not duplicate a tag the composer field already filed" do
      user = confirmed_user()
      tag = tag_named("elixir")

      {:ok, post} =
        Posts.create_post(user, %{body: "Writing ##{tag.slug} today.", tags: [tag.name]})

      # The chip row owns it; a second filing would put the post on the tag page
      # twice.
      assert filed_tag_ids(post) == []
      assert Enum.map(Repo.preload(post, :tags).tags, & &1.id) == [tag.id]
    end

    test "an edit that drops the hashtag drops the filing" do
      user = confirmed_user()
      tag = tag_named("berlin")

      {:ok, post} = Posts.create_post(user, %{body: "Hello ##{tag.slug}"})
      assert filed_tag_ids(post) == [tag.id]

      {:ok, post} = Posts.update_post(post, %{body: "Hello nowhere in particular"})
      assert filed_tag_ids(post) == []
    end

    test "the hashtag does not become a tag chip on the card" do
      user = confirmed_user()
      tag = tag_named("berlin")

      {:ok, post} = Posts.create_post(user, %{body: "Hello ##{tag.slug}"})

      # The hashtag is already visible in the sentence; a chip would print it
      # twice.
      assert Repo.preload(post, :tags).tags == []
    end

    test "may name more hashtags than the tag field takes" do
      user = confirmed_user()
      tags = for n <- 1..(Posts.max_tags_per_post() + 3), do: tag_named("berlin#{n}")
      body = "Writing about " <> Enum.map_join(tags, " ", &"##{&1.slug}")

      # The cap (issue #1237) belongs to the composer's tag field, which fills
      # the chip row. Filing by hashtag is a different table with a different
      # job — listing the post on every tag page its text points at — so a body
      # full of hashtags saves as written.
      assert {:ok, post} = Posts.create_post(user, %{body: body})

      assert Enum.sort(filed_tag_ids(post)) == Enum.sort(Enum.map(tags, & &1.id))
    end
  end

  describe "a cached remote post" do
    test "is filed from the ActivityPub tag array" do
      tag = tag_named("berlin")
      post = remote_post("Nothing in the text.")

      Hashtags.sync(post, %{
        "tag" => [
          %{"type" => "Hashtag", "name" => "#" <> tag.slug, "href" => "https://social.example/t"},
          %{"type" => "Mention", "name" => "@them@social.example", "href" => "https://x/y"}
        ]
      })

      assert filed_tag_ids(post) == [tag.id]
    end

    test "is filed from the text when the server sends no tag objects" do
      tag = tag_named("berlin")
      post = remote_post("Grüße aus ##{tag.slug}!")

      Hashtags.sync(post, %{})

      assert filed_tag_ids(post) == [tag.id]
    end

    test "mints no tag from a stranger's hashtag" do
      unknown = "fromoverthere_#{System.unique_integer([:positive])}"
      post = remote_post("Trending: ##{unknown}")

      Hashtags.sync(post, %{"tag" => [%{"type" => "Hashtag", "name" => "#" <> unknown}]})

      assert filed_tag_ids(post) == []
      refute Repo.exists?(from(t in Vutuv.Tags.Tag, where: t.slug == ^unknown))
    end

    test "an upstream edit re-syncs the filings both ways" do
      kept = tag_named("kept")
      dropped = tag_named("dropped")
      added = tag_named("added")

      post = remote_post("##{kept.slug} ##{dropped.slug}")
      Hashtags.sync(post, %{})
      assert Enum.sort(filed_tag_ids(post)) == Enum.sort([kept.id, dropped.id])

      edited = %{post | content_text: "##{kept.slug} ##{added.slug}"}
      Hashtags.sync(edited, %{})

      assert Enum.sort(filed_tag_ids(post)) == Enum.sort([kept.id, added.id])
    end

    test "syncing twice files one row per tag" do
      tag = tag_named("berlin")
      post = remote_post("##{tag.slug}")

      Hashtags.sync(post, %{})
      Hashtags.sync(post, %{})

      assert filed_tag_ids(post) == [tag.id]
    end
  end

  describe "Tags.tag_ids_for_hashtags/1" do
    test "matches an existing tag by name as well as by slug" do
      # A member spelled it "München"; the slug is transliterated, so a remote
      # `#münchen` would never match on the slug alone.
      tag = insert(:tag, name: "München-#{System.unique_integer([:positive])}", slug: "muenchen")

      assert Tags.tag_ids_for_hashtags([String.downcase(tag.name)]) == [tag.id]
      assert Tags.tag_ids_for_hashtags(["muenchen"]) == [tag.id]
      assert Tags.tag_ids_for_hashtags([]) == []
    end
  end
end
