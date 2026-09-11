defmodule VutuvWeb.WithheldPostRedactionTest do
  @moduledoc """
  A post whose author keeps machines away (issue #2107) is redacted wherever a
  **machine** reads it — and the HTML conversation still shows it to people.

  The switch protected the post's own documents from the start; what it did not
  protect was the post as it appears **inside somebody else's**. Measured over
  HTTP before the fix: a reply's permalink and all four of its agent formats
  served the withheld parent's complete body under
  `Content-Signal: ai-train=yes` with no `X-Robots-Tag` at all, because the
  header axes of a document are computed from its **subject** post and a
  conversation quotes other people's. The same hole ran through a repost onto
  the reposter's public archive and through the profile document's pinned-post
  excerpt.

  Page and doc differ here **on purpose**: the promise is about machines, not
  about readers, so the permalink's HTML thread keeps every word. The one place
  they must agree is the archive listing, which is a crawl surface — its doc
  already omitted the quoted parent while the page printed it in full.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Repo
  alias VutuvWeb.AgentDocs.PostDoc

  @withheld "Interne Preisliste, nur für Menschen."

  # The parent is withheld, the reply is not: the reply's own document is
  # wide open and quotes the parent, which is exactly the hole.
  defp withheld_parent_with_reply do
    author = insert(:activated_user, noindex?: false, noai?: false)
    replier = insert(:activated_user, noindex?: false, noai?: false)

    {:ok, parent} = Posts.create_post(author, %{body: @withheld, noindex_noai: "true"})
    {:ok, reply} = Posts.create_reply(replier, parent, %{body: "Danke für die Zahlen!"})

    %{author: author, replier: replier, parent: parent, reply: reply}
  end

  describe "a conversation a machine reads" do
    test "the reply's agent formats quote the withheld parent by name, not by body", %{conn: conn} do
      %{replier: replier, reply: reply, parent: parent} = withheld_parent_with_reply()

      doc = conn |> get("/#{replier.username}/posts/#{reply.id}.json") |> json_response(200)

      quoted = Enum.find(doc["thread"], &(&1["id"] == parent.id))

      assert quoted, "the withheld parent keeps its place in the conversation"
      refute quoted["body_markdown"] =~ "Preisliste"
      assert quoted["body_markdown"] == "Post not open to search engines"

      # The reply itself is untouched — one post's answer is not another's.
      assert doc["body_markdown"] =~ "Danke für die Zahlen!"
    end

    test "the same is true of the Markdown sibling", %{conn: conn} do
      %{replier: replier, reply: reply} = withheld_parent_with_reply()

      body = conn |> get("/#{replier.username}/posts/#{reply.id}.md") |> response(200)

      refute body =~ "Preisliste"
      assert body =~ "Post not open to search engines"
    end

    test "a withheld reply under an open post gives up its words too", %{conn: conn} do
      author = insert(:activated_user, noindex?: false, noai?: false)
      replier = insert(:activated_user, noindex?: false, noai?: false)

      {:ok, post} = Posts.create_post(author, %{body: "Ganz offen"})
      {:ok, _reply} = Posts.create_reply(replier, post, %{body: @withheld, noindex_noai: "true"})

      doc = conn |> get("/#{author.username}/posts/#{post.id}.json") |> json_response(200)

      assert [entry] = doc["replies"]
      refute entry["body_markdown"] =~ "Preisliste"
      assert entry["body_markdown"] == "Post not open to search engines"
    end

    test "but the HTML conversation still shows it to a person", %{conn: conn} do
      %{replier: replier, reply: reply} = withheld_parent_with_reply()

      html = conn |> get("/#{replier.username}/posts/#{reply.id}") |> html_response(200)

      # Page and doc differ on purpose. The thread is rendered by an embedded
      # LiveView, so the dead render is what this asserts — which is the render
      # a crawler would get, and it carries the reply's own robots axes rather
      # than the parent's. That is the accepted trade: the promise is about the
      # machine documents, and a human reading a conversation sees all of it.
      assert html =~ "Danke für die Zahlen!"
    end
  end

  describe "a repost of a withheld post" do
    test "is off the reposter's public archive, page and document alike", %{conn: conn} do
      author = insert(:activated_user, noindex?: false, noai?: false)
      reposter = insert(:activated_user, noindex?: false, noai?: false)

      {:ok, withheld} = Posts.create_post(author, %{body: @withheld, noindex_noai: "true"})
      {:ok, open} = Posts.create_post(author, %{body: "Ganz offen"})
      :ok = Posts.repost_post(reposter, withheld)
      :ok = Posts.repost_post(reposter, open)

      html = conn |> get("/#{reposter.username}/posts") |> html_response(200)
      refute html =~ "Preisliste"
      assert html =~ "Ganz offen"

      doc = conn |> get("/#{reposter.username}/posts.json") |> json_response(200)
      refute Jason.encode!(doc) =~ "Preisliste"
    end

    test "and off the reposter's profile document", %{conn: conn} do
      author = insert(:activated_user, noindex?: false, noai?: false)
      reposter = insert(:activated_user, noindex?: false, noai?: false)

      {:ok, withheld} = Posts.create_post(author, %{body: @withheld, noindex_noai: "true"})
      :ok = Posts.repost_post(reposter, withheld)

      doc = conn |> get("/#{reposter.username}.json") |> json_response(200)

      refute Jason.encode!(doc) =~ "Preisliste"
    end
  end

  describe "a withheld post pinned to its own author's profile" do
    test "keeps its place in the profile document and gives up its excerpt", %{conn: conn} do
      author = insert(:activated_user, noindex?: false, noai?: false)
      {:ok, post} = Posts.create_post(author, %{body: @withheld, noindex_noai: "true"})
      {:ok, author} = Posts.pin_to_profile(author, post)

      doc = conn |> get("/#{author.username}.json") |> json_response(200)

      refute Jason.encode!(doc) =~ "Preisliste"
    end
  end

  describe "a reader who is allowed to read it is not redacted at" do
    # A redaction that hits somebody entitled to the text is as wrong as a
    # missing one. Both of these are login-gated and per-viewer: the feed
    # document declares `noindex: true, noai: true` over the whole response, and
    # `/api/2.0` is a token read on a member's behalf. Either way that person
    # opens the permalink and reads every word, so the sentence would take
    # something away and tell them nothing.
    test "the feed document", %{conn: _conn} do
      %{parent: parent} = withheld_parent_with_reply()
      reader = insert(:activated_user)

      entry = PostDoc.timeline_entry(%{post: Posts.get_post(parent.id)}, reader)

      assert entry.excerpt =~ "Preisliste"
      refute entry.excerpt == "Post not open to search engines"
    end

    test "a permalink read through the API on a member's behalf" do
      %{author: author, parent: parent, reply: reply} = withheld_parent_with_reply()
      reader = insert(:activated_user)

      loaded = Posts.get_post(reply.id)
      doc = PostDoc.build(Posts.author(loaded), loaded, viewer: reader)
      quoted = Enum.find(doc.thread, &(&1.id == parent.id))

      assert quoted.body_markdown =~ "Preisliste"
      # …and the anonymous build of the very same post still redacts it.
      anonymous = PostDoc.build(Posts.author(loaded), loaded)

      assert Enum.find(anonymous.thread, &(&1.id == parent.id)).body_markdown ==
               "Post not open to search engines"

      assert author
    end
  end

  describe "an author reading their own archive" do
    test "keeps the quoted parent above their own reply to their own withheld post", %{conn: conn} do
      author = insert(:activated_user, noindex?: false, noai?: false, emails: [build(:email)])
      {:ok, parent} = Posts.create_post(author, %{body: @withheld, noindex_noai: "true"})
      {:ok, _reply} = Posts.create_reply(author, parent, %{body: "Nachtrag von mir."})

      html =
        conn
        |> login_via_pin(hd(author.emails).value)
        |> get("/#{author.username}/posts")
        |> html_response(200)

      # The archive already shows an author their own withheld posts, so
      # dropping the quote one row down made a single page disagree with
      # itself. `public_ancestors/2` takes the viewer for exactly this.
      assert html =~ "Nachtrag von mir."
      assert html =~ "Preisliste"
    end
  end

  describe "a private page a machine never reads" do
    test "keeps the quoted parent on the reader's own bookmarks", %{conn: conn} do
      %{parent: parent, reply: reply} = withheld_parent_with_reply()
      {conn, reader} = create_and_login_user(conn)
      :ok = Posts.bookmark_post(reader, reply)

      {:ok, _live, html} = live(conn, ~p"/bookmarks")

      # `/likes` and `/bookmarks` are login-only, so no crawler reaches them and
      # the policy has no business there. This is the calibration for keeping
      # the gate in `Posts.public_ancestors/1` rather than in the shared card
      # component, where it would have taken a member's own quoted parent away.
      assert html =~ "Danke für die Zahlen!"
      assert html =~ "Preisliste"
      assert Repo.get!(Vutuv.Posts.Post, parent.id)
    end
  end

  describe "the archive's quoted parent" do
    test "is not printed on the public page either, which its own document omits", %{conn: conn} do
      %{replier: replier, reply: reply} = withheld_parent_with_reply()

      html = conn |> get("/#{replier.username}/posts") |> html_response(200)

      # The archive is a crawl surface — this branch already drops a withheld
      # post of the page owner's own from it — so the parent quoted above a
      # reply card must go the same way. Its `.md`/`.json` siblings carry no
      # thread for an archive entry at all, so this is also what stops the page
      # and the document disagreeing.
      refute html =~ "Preisliste"
      assert html =~ "Danke für die Zahlen!"
      assert Repo.get!(Vutuv.Posts.Post, reply.id)
    end
  end
end
