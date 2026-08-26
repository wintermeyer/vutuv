defmodule VutuvWeb.MentionFormTest do
  @moduledoc """
  One stored body, two spellings of the same mention: short inside vutuv, in
  full on the way out.

  A member writes `@ada`; a server on the other side of the Fediverse writes
  `@ada@vutuv.de` for the same person. Each spelling is the right one exactly
  where it was written and wrong where the other one lives — a bare `@ada` on
  mastodon.social names *their* member of that name, and `@ada@vutuv.de` on a
  vutuv page spells out the host the reader is already on. So the form is
  decided at render time, on both sides, and the post itself is never rewritten:
  the body keeps whatever was typed, which is what lets the same row read
  correctly in both places.

  `async: false` and its own file because `with_endpoint_host/1` changes global
  endpoint config the SQL sandbox does not roll back; the test endpoint's
  "localhost" has no dot and cannot match the address grammar at all.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.EndpointHostHelper
  import Vutuv.Factory

  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts.Post
  alias VutuvWeb.Fediverse.Docs
  alias VutuvWeb.Markdown
  alias VutuvWeb.PostTeaser

  setup do
    with_endpoint_host("vutuv.test")
    :ok
  end

  defp member(attrs \\ []) do
    handle = "ada#{System.unique_integer([:positive])}"

    insert(
      :activated_user,
      Keyword.merge(
        [
          username: handle,
          first_name: "Ada",
          last_name: "Lovelace",
          fediverse_followers?: true
        ],
        attrs
      )
    )
  end

  defp page(%Post{body: body}), do: body |> Markdown.render_post([]) |> safe_to_string()

  defp safe_to_string(safe), do: Phoenix.HTML.safe_to_string(safe)

  defp note(post, author), do: Docs.create_activity(post, author)["object"]

  defp mention_tags(note) do
    note["tag"] |> List.wrap() |> Enum.filter(&(&1["type"] == "Mention"))
  end

  describe "a bare @handle" do
    test "stays short on the page and is spelled out in the Note" do
      author = member()
      ada = member()
      post = insert(:post, user: author, body: "Hallo @#{ada.username}, willkommen!")

      assert page(post) =~ ~s(class="mention">@#{ada.username}</a>)

      content = note(post, author)["content"]
      assert content =~ ~s(>@#{ada.username}@vutuv.test</a>)
      # The link still points at the profile page — absolute, because a remote
      # server renders this HTML on its own domain.
      assert content =~ ~s(href="#{VutuvWeb.Endpoint.url()}/#{ada.username}")
    end

    test "of a handle nobody holds is left alone in both places" do
      author = member()
      post = insert(:post, user: author, body: "Hallo @nobody_here!")

      assert page(post) =~ "@nobody_here"
      refute page(post) =~ "<a"

      content = note(post, author)["content"]
      assert content =~ "@nobody_here"
      refute content =~ "@nobody_here@vutuv.test"
    end
  end

  describe "an address on our own host" do
    test "reads short on the page and travels whole" do
      author = member()
      ada = member()
      post = insert(:post, user: author, body: "Hallo @#{ada.username}@vutuv.test, willkommen!")

      html = page(post)
      assert html =~ ~s(class="mention">@#{ada.username}</a>)
      refute html =~ "vutuv.test"

      assert note(post, author)["content"] =~ ~s(>@#{ada.username}@vutuv.test</a>)
    end

    test "leaves the stored body untouched, whichever way it was rendered" do
      author = member()
      ada = member()
      body = "Hallo @#{ada.username}@vutuv.test und @#{ada.username}!"
      post = insert(:post, user: author, body: body)

      page(post)
      note(post, author)

      assert Repo.get!(Post, post.id).body == body
    end

    test "is shortened in the plain-text surfaces too" do
      ada = member()

      assert Markdown.to_plain_text("Hallo @#{ada.username}@vutuv.test!") ==
               "Hallo @#{ada.username}!"
    end

    # The one spelling a post from another network has for us, on the surface
    # with the least room for it. No lookup happens: the handle here is nobody.
    test "reads short in the tab teaser of a post from another network" do
      remote = %RemotePost{content_text: "Hallo @patrick@vutuv.test, willkommen!"}

      assert PostTeaser.text(%{remote_post: remote}) == "Hallo @patrick, willkommen!"
    end

    # The card a reply from another network is read in — the surface that shows
    # our members named in full more often than any other, because over there
    # the full address is the only way to name us. It renders through
    # `render_remote/1` rather than `render_post/2`, a second pipeline with its
    # own linkify call, so it needs its own test: everything else here could be
    # green while the one card a member actually reads a mention of themselves
    # in still spelled out the host.
    test "reads short in the body of a reply from another network" do
      ada = member()

      html = Markdown.render_remote("@#{ada.username}@vutuv.test Ggf. reicht es aus.")

      assert html =~ ~s(class="mention">@#{ada.username}</a>)
      refute html =~ "vutuv.test"
    end

    # A handle nobody here holds — the member has left, or the remote server
    # named a page of ours that never existed. Shortened too: a dead handle
    # reads no better for carrying our host, and the alternative is one
    # sentence spelling two mentions two different ways.
    test "of a handle nobody holds still reads short in remote content" do
      html = Markdown.render_remote("@departed@vutuv.test war hier.")

      assert html =~ "@departed"
      refute html =~ "vutuv.test"
    end

    # Somebody else's account, in the same sentence. The rule is about *our*
    # host and nothing else: shortening this one would name a vutuv member of
    # that name, who is a different person.
    test "on another server is left whole" do
      html = Markdown.render_remote("@feb@social.example und @patrick@vutuv.test")

      assert html =~ "@feb@social.example"
      assert html =~ "@patrick"
      refute html =~ "@patrick@vutuv.test"
    end

    # `https://mastodon.social/@ada@vutuv.test` is Mastodon's web path to a
    # remote profile, not a mention — and shortened it names *their* @ada, who
    # is somebody else. The rendered body is safe by accident (the autolinker
    # has made it an anchor and the entity pass skips those), so the plain-text
    # route is where this has to be tested.
    test "inside a URL is left alone, address and prose in the same line" do
      ada = member()

      # The URL's own display drops the scheme (the autolinker's doing), so the
      # path is what this asserts on: it still names the account it did.
      text =
        Markdown.to_plain_text(
          "Siehe https://mastodon.social/@#{ada.username}@vutuv.test — oder @#{ada.username}@vutuv.test fragen."
        )

      assert text =~ "mastodon.social/@#{ada.username}@vutuv.test"
      assert text =~ "oder @#{ada.username} fragen"
    end

    # The slash that is not a URL. German prose writes an account name straight
    # after one, and there the short form is right — the same account, spelled
    # the way this site spells it.
    test "after a slash in prose still reads short" do
      assert Markdown.to_plain_text("Bündnis 90/@gruene@vutuv.test dazu") ==
               "Bündnis 90/@gruene dazu"
    end
  end

  describe "the Mention tags on an outgoing Note" do
    test "name our own accounts by their actor, so the other side can resolve them" do
      author = member()
      ada = member()
      post = insert(:post, user: author, body: "Hallo @#{ada.username}!")

      assert [mention] = mention_tags(note(post, author))
      assert mention["href"] == Docs.actor_url(ada)
      assert mention["name"] == "@#{ada.username}@vutuv.test"
    end

    test "cover a page named by its handle as well" do
      author = member()
      handle = "acme#{System.unique_integer([:positive])}"

      organization =
        insert(:organization, username: handle, name: "Acme GmbH", fediverse_followers?: true)

      post = insert(:post, user: author, body: "Wir bauen mit @#{handle}.")

      assert [mention] = mention_tags(note(post, author))
      assert mention["href"] == Docs.actor_url(organization)
      assert mention["name"] == "@#{handle}@vutuv.test"
    end

    # The address is who is meant whether or not they federate, and it links to
    # the profile page either way. A Mention would point every receiving server
    # at an actor document this member does not serve.
    test "leave out a member who keeps out of the Fediverse — the text still names them" do
      author = member()
      quiet = member(fediverse_followers?: false)
      post = insert(:post, user: author, body: "Hallo @#{quiet.username}!")

      note = note(post, author)

      assert note["content"] =~ ~s(>@#{quiet.username}@vutuv.test</a>)
      assert mention_tags(note) == []
    end

    # Minting a Mention from typed text is only safe because every handle here
    # is resolved against our own tables. An account on somebody else's server
    # is nobody we have checked, and vouching for it with our signature is what
    # mention spam looks like.
    test "are never minted for an address on another server" do
      author = member()
      post = insert(:post, user: author, body: "Hallo @bob@geno.social!")

      note = note(post, author)

      assert note["content"] =~ ~s(href="https://geno.social/@bob")
      assert mention_tags(note) == []
    end
  end
end
