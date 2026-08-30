defmodule Vutuv.HashtagFilingTest do
  @moduledoc """
  Filing a post under the tags its `#hashtags` name, on both sides of the fence:
  a member's post body (`Vutuv.Posts.PostHashtag`) and a cached remote post
  (`Vutuv.Fediverse.Hashtags`).

  The rule both sides share is that a hashtag naming a topic nobody here has
  written about yet **mints** it — writing `#Eisenach` declares a tag as plainly
  as typing it into the composer's tag field — bounded by
  `Vutuv.Tags.mintable_hashtag?/1` and `Tags.max_minted_hashtags_per_body/0`.
  """
  use Vutuv.DataCase

  alias Vutuv.Fediverse.Hashtags
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Fediverse.RemotePostTag
  alias Vutuv.Mentions
  alias Vutuv.Posts
  alias Vutuv.Posts.PostHashtag
  alias Vutuv.SlugHelpers
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag

  defp confirmed_user, do: insert(:user, email_confirmed?: true)

  # A tag whose slug is a valid hashtag. The factory's `unique_tag_name/1`
  # separates with a hyphen, which the `#hashtag` grammar ends the tag at — so
  # `#berlin-7` would name the tag `berlin`, not this one.
  defp tag_named(base) do
    name = "#{base}_#{System.unique_integer([:positive])}"
    insert(:tag, name: name, slug: SlugHelpers.tagify(name))
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

    test "a hashtag runs to the end of the word in any language" do
      # ASCII-only, `#Thüringen` stopped at the `ü` and named the tag `th`. On a
      # German site that is most hashtags, so the grammar spans Unicode letters,
      # marks and digits — the class Mastodon uses, where these arrive from.
      assert Mentions.hashtags("#Eisenach und #Thüringen") == ["eisenach", "thüringen"]
      assert Mentions.hashtags("#ÖPNV #Grüße #straße") == ["öpnv", "grüße", "straße"]
      assert Mentions.hashtags("#日本語") == ["日本語"]
    end

    test "the fediverse address form still names a mention, not a hashtag" do
      # The lookbehinds now read `\\w` as Unicode too, which is the intended
      # meaning of "not mid-token" — but a full `@user@host` after a slash is
      # still the address itself (issue #1694).
      assert Mentions.hashtags("Bündnis 90/@gruenebundestag@gruene.social") == []
    end
  end

  describe "Mentions.written_hashtags/1" do
    test "keeps the spelling the body used, deduped case-insensitively" do
      # A minted tag is stored the way whoever names it first wrote it, so the
      # mint path needs the written form; `hashtags/1` lowercases for lookups.
      assert Mentions.written_hashtags("#Thüringen and #Eisenach") == ["Thüringen", "Eisenach"]
      assert Mentions.written_hashtags("#Berlin #berlin #BERLIN") == ["Berlin"]
      assert Mentions.written_hashtags(nil) == []
    end
  end

  describe "a member's post body" do
    test "is filed under an existing tag its hashtag names" do
      user = confirmed_user()
      tag = tag_named("berlin")

      {:ok, post} = Posts.create_post(user, %{body: "Moving to ##{tag.slug} next week."})

      assert filed_tag_ids(post) == [tag.id]
    end

    test "mints the tag an unknown hashtag names, and files the post under it" do
      user = confirmed_user()
      unknown = "Nosuchtag_#{System.unique_integer([:positive])}"

      {:ok, post} = Posts.create_post(user, %{body: "About ##{unknown}."})

      assert [tag_id] = filed_tag_ids(post)
      tag = Repo.get!(Tag, tag_id)
      # Stored as written: vutuv keeps a tag's name the way its first writer
      # typed it, and a hashtag is now one of the ways a tag is first written.
      assert tag.name == unknown
      assert tag.slug == String.downcase(unknown)
    end

    test "mints a German hashtag under the slug it transliterates to" do
      user = confirmed_user()
      name = "Thueringen#{System.unique_integer([:positive])}"
      written = String.replace(name, "ue", "\u00fc", global: false)

      {:ok, post} = Posts.create_post(user, %{body: "Neu in ##{written}."})

      assert [tag_id] = filed_tag_ids(post)
      tag = Repo.get!(Tag, tag_id)
      # The name keeps the umlaut; the slug is the URL and the fediverse actor
      # name, so it transliterates. This is the pair the old ASCII-only grammar
      # could not produce at all - it read the hashtag as `#Th`.
      assert tag.name == written
      assert tag.slug == String.downcase(name)
    end

    test "a second post writing the same hashtag re-uses the minted tag" do
      user = confirmed_user()
      name = "Eisenach#{System.unique_integer([:positive])}"

      {:ok, first} = Posts.create_post(user, %{body: "Aus ##{name}."})
      {:ok, second} = Posts.create_post(user, %{body: "Wieder ##{String.downcase(name)}!"})

      assert filed_tag_ids(first) == filed_tag_ids(second)
      assert Repo.aggregate(from(t in Tag, where: ilike(t.name, ^name)), :count) == 1
    end

    test "mints nothing for a hashtag whose slug would not name it" do
      user = confirmed_user()

      # `#2026` slugs to `2026` and a CJK hashtag transliterates to nothing at
      # all (which `gen_tag_slug_unique/3` fills with random hex). Neither URL
      # says what the page is about, so neither is minted in passing - a member
      # who wants such a tag can still create it by hand on the tags page.
      {:ok, post} = Posts.create_post(user, %{body: "Im #2026 und #\u65e5\u672c\u8a9e."})

      assert filed_tag_ids(post) == []
      refute Repo.exists?(from(t in Tag, where: t.slug == "2026"))
    end

    test "mints nothing when the post is refused for having too many chips" do
      user = confirmed_user()
      name = "Doomed#{System.unique_integer([:positive])}"
      chips = for n <- 1..(Posts.max_tags_per_post() + 1), do: "#{name}chip#{n}"

      # The sixth chip fails the save (issue #1237), so the body's hashtag must
      # not leave a tag page behind for a post that never published. Minting
      # happens while the changeset is built, before that error is added, so the
      # decision has to be handed down rather than discovered.
      assert {:error, _changeset} =
               Posts.create_post(user, %{body: "About ##{name}.", tags: chips})

      refute Repo.exists?(from(t in Tag, where: ilike(t.name, ^name)))
    end

    test "mints at most five tags from one body" do
      user = confirmed_user()
      run = System.unique_integer([:positive])
      names = for n <- 1..(Tags.max_minted_hashtags_per_body() + 3), do: "Minted#{run}x#{n}"
      body = "Ueber " <> Enum.map_join(names, " ", &"##{&1}")

      {:ok, post} = Posts.create_post(user, %{body: body})

      # Filing under existing tags is cheap; minting creates a public page, so
      # the two carry different ceilings.
      assert length(filed_tag_ids(post)) == Tags.max_minted_hashtags_per_body()
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

    test "mints the tag a followed account's hashtag names" do
      # Nothing reaches this module unless a member here follows the sender
      # (`Fediverse.record_remote_post/2` requires an accepted follow), so these
      # are the topics our own members chose to read about.
      name = "Fromoverthere#{System.unique_integer([:positive])}"
      post = remote_post("Trending: ##{name}")

      Hashtags.sync(post, %{"tag" => [%{"type" => "Hashtag", "name" => "#" <> name}]})

      assert [tag_id] = filed_tag_ids(post)
      assert Repo.get!(Tag, tag_id).name == name
    end

    test "a NUL inside an AP hashtag name files the post instead of raising" do
      # The reported delivery (#1825). The key is bound into a SELECT, so the
      # byte took the query down before any write — see `Vutuv.Tags.MatchKey`
      # for why it belongs with the zero-width characters.
      tag = tag_named("berlin")
      [head, tail] = String.split(tag.slug, "", parts: 2)
      post = remote_post("Nothing in the text.")

      Hashtags.sync(post, %{
        "tag" => [%{"type" => "Hashtag", "name" => "#" <> head <> <<0>> <> tail}]
      })

      assert filed_tag_ids(post) == [tag.id]
    end

    test "a NUL in a hashtag that mints its tag is gone from the stored name" do
      # The same delivery down the other branch: nothing answers to the name
      # yet, so it is written rather than found. End to end on purpose — which
      # of the two guards broke is what `Vutuv.Tags.TagTest` isolates.
      name = "Fromoverthere#{System.unique_integer([:positive])}"
      post = remote_post("Nothing in the text.")

      Hashtags.sync(post, %{
        "tag" => [%{"type" => "Hashtag", "name" => "#Fromoverthere" <> <<0>> <> name}]
      })

      assert [tag_id] = filed_tag_ids(post)
      refute String.contains?(Repo.get!(Tag, tag_id).name, <<0>>)
    end

    test "keeps the casing the AP tag array sent" do
      name = "Gr\u00fcne#{System.unique_integer([:positive])}"
      post = remote_post("Nothing in the text.")

      Hashtags.sync(post, %{"tag" => [%{"type" => "Hashtag", "name" => "#" <> name}]})

      assert [tag_id] = filed_tag_ids(post)
      assert Repo.get!(Tag, tag_id).name == name
    end

    test "a minted tag page stays out of the sitemap until something local carries it" do
      # The bound that makes minting from another network safe: a remote post
      # can leave a tag page behind, it cannot put one in front of a crawler.
      name = "Remoteonly#{System.unique_integer([:positive])}"
      post = remote_post("About ##{name}")

      Hashtags.sync(post, %{})

      assert [tag_id] = filed_tag_ids(post)
      refute Tags.indexable_tag?(Repo.get!(Tag, tag_id))
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

  describe "Tags.tag_ids_for_hashtags/2" do
    test "matches an existing tag by name as well as by slug" do
      # A member spelled it "München"; the slug is transliterated, so a remote
      # `#münchen` would never match on the slug alone.
      tag = insert(:tag, name: "München-#{System.unique_integer([:positive])}", slug: "muenchen")

      assert Tags.tag_ids_for_hashtags([String.downcase(tag.name)]) == [tag.id]
      assert Tags.tag_ids_for_hashtags(["muenchen"]) == [tag.id]
      assert Tags.tag_ids_for_hashtags([]) == []
    end

    test "an underscore in a hashtag reaches the spaced tag it names" do
      # The folded key (`Vutuv.Tags.MatchKey`) collapses space, hyphen and
      # underscore alike, so `#ruby_on_rails` is the tag "Ruby on Rails" rather
      # than a second page for it. Matching this well is what makes minting
      # safe: every spelling a lookup misses is a duplicate it would create.
      name = "Ruby on Rails #{System.unique_integer([:positive])}"
      tag = insert(:tag, name: name, slug: SlugHelpers.tagify(name))

      assert Tags.tag_ids_for_hashtags([String.replace(name, " ", "_")], create: true) == [tag.id]
    end

    test "without create: true it still mints nothing" do
      unknown = "Neverminted#{System.unique_integer([:positive])}"

      assert Tags.tag_ids_for_hashtags([unknown]) == []
      refute Repo.exists?(from(t in Tag, where: ilike(t.name, ^unknown)))
    end
  end

  describe "Tags.mintable_hashtag?/1" do
    test "refuses what would not make a tag, or would not make a slug" do
      assert Tags.mintable_hashtag?("Th\u00fcringen")
      assert Tags.mintable_hashtag?("elixir_lang")

      # No letter survives into the slug, so the URL would not name the page.
      refute Tags.mintable_hashtag?("2026")
      refute Tags.mintable_hashtag?("\u65e5\u672c\u8a9e")

      # The rules `Tag.changeset/2` applies, asked before the insert.
      refute Tags.mintable_hashtag?("...")
      refute Tags.mintable_hashtag?("example.com")
      refute Tags.mintable_hashtag?(nil)
    end
  end

  describe "the renderer and the filing agree" do
    test "a hashtag links to the page its post was filed under" do
      # Filing has always matched a tag by name as well as slug while
      # `linkable_slugs/1` matched the slug alone, so `#München` sat as plain
      # text in a post the München page listed. Minting made that the common
      # case, since every German hashtag has a transliterated slug.
      user = confirmed_user()
      name = "Th\u00fcringen#{System.unique_integer([:positive])}"

      {:ok, post} = Posts.create_post(user, %{body: "Neu in ##{name}."})
      assert [tag_id] = filed_tag_ids(post)
      tag = Repo.get!(Tag, tag_id)

      # The post itself is what makes the page worth a click.
      written = String.downcase(name)
      assert Tags.linkable_slugs([written]) == %{written => tag.slug}
    end
  end
end
