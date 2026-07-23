defmodule VutuvWeb.PostControllerTest do
  @moduledoc """
  The permalink page: public posts are crawlable, restricted posts noindex
  and hide from denied readers, the teaser appears only for the
  non_followers-only case, and the deny list never leaks to readers.
  """
  use VutuvWeb.ConnCase

  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.ReviewCover

  @other_login_attrs %{
    "emails" => %{"0" => %{"value" => "other@example.com"}},
    "first_name" => "other",
    "tag_list" => @registration_tags
  }

  defp fresh_conn do
    Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
  end

  defp pad(int), do: String.pad_leading(Integer.to_string(int), 2, "0")

  # Where `text` first shows up in the rendered page — how the thread tests
  # assert reading order without parsing the whole card tree.
  defp position(html, text) do
    case :binary.match(html, text) do
      {at, _} -> at
      :nomatch -> flunk("#{inspect(text)} is not on the page")
    end
  end

  describe "the review card on the permalink" do
    # Stores a served cover version for `review` under a throwaway uploads
    # tree, so the card renders the <img> (and its source credit) instead of
    # the kind-glyph placeholder.
    defp store_cover!(review) do
      tmp = Path.join(System.tmp_dir!(), "vutuv_card_cover_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      previous = Application.get_env(:vutuv, :uploads_dir_prefix)
      Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

      on_exit(fn ->
        File.rm_rf(tmp)

        if previous,
          do: Application.put_env(:vutuv, :uploads_dir_prefix, previous),
          else: Application.delete_env(:vutuv, :uploads_dir_prefix)
      end)

      src = Path.join(tmp, "cover.jpg")
      {:ok, image} = Image.new(120, 180, color: [10, 120, 200])
      {:ok, _} = Image.write(image, src)
      {:ok, file} = ReviewCover.store_binary(File.read!(src), review)

      review
      |> Ecto.Changeset.change(%{cover: file, cover_status: "ready"})
      |> Repo.update!()
    end

    defp reviewed_post!(user) do
      create_post!(user, %{
        body: "Sehr lesenswert.",
        review: %{
          "kind" => "book",
          "identifier" => "978-3-16-148410-0",
          "title" => "Refactoring",
          "creator" => "Martin Fowler",
          "year" => "2018",
          "medium" => "audiobook"
        }
      })
    end

    test "shows card, medium, shop link and Review JSON-LD", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      html = conn |> get(Posts.path(post)) |> html_response(200)

      assert html =~ "data-review-card"
      # No "Book review" caption on the card: the cover, the title and the
      # medium say what it is. Machines still get the kind from the JSON-LD
      # below and from the agent-format siblings.
      refute html =~ ">Book review<"
      assert html =~ "Refactoring"
      assert html =~ "Martin Fowler"
      assert html =~ "Audiobook"
      assert html =~ "https://www.amazon.de/dp/316148410X"
      # The structured data marks the post as a Review of the Book.
      assert html =~ "itemReviewed"
      assert html =~ ~s("isbn": "9783161484100")
    end

    test "shows the publisher, the page count and an audiobook's running time", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      post.review
      |> Ecto.Changeset.change(%{pages: 448, publisher: "Addison-Wesley", duration_minutes: 440})
      |> Repo.update!()

      doc = conn |> get(Posts.path(post)) |> html_response(200) |> LazyHTML.from_document()
      html = LazyHTML.to_html(doc)

      # The publisher is named, not left as a bare word that could be anything.
      assert html =~ "Publisher: Addison-Wesley"
      assert html =~ "7 h 20 min"

      # The page count reads as the bare figure under the cover. The review is
      # of the audiobook (medium "audiobook"), whose recording has no pages —
      # that the number is the print edition's is what the hover title says,
      # so the card keeps the short line and the fact stays available.
      pages = LazyHTML.query(doc, "[data-review-card] [data-review-pages]")

      assert LazyHTML.text(pages) =~ "448 pages"
      refute LazyHTML.text(pages) =~ "print edition"
      assert LazyHTML.attribute(pages, "title") == ["448 pages (print edition)"]
    end

    test "a runtime borrowed from another edition reads as approximate", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      # The review carries the print ISBN; the runtime came from the work's
      # audio edition (duration_isbn), so it must not read as this
      # edition's stated length — and it stays out of the structured data,
      # which has no way to say "approximately".
      post.review
      |> Ecto.Changeset.change(%{duration_minutes: 75, duration_isbn: "9783837170825"})
      |> Repo.update!()

      html = conn |> get(Posts.path(post)) |> html_response(200)

      assert html =~ "approx. 1 h 15 min"
      refute html =~ "PT1H15M"
    end

    test "an exact runtime reads plainly and reaches the structured data", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      post.review
      |> Ecto.Changeset.change(%{duration_minutes: 75, duration_isbn: nil})
      |> Repo.update!()

      html = conn |> get(Posts.path(post)) |> html_response(200)

      assert html =~ "1 h 15 min"
      refute html =~ "approx."
      # An audiobook is its own schema.org type, and only a stated length
      # belongs in it.
      assert html =~ ~s("@type": "Audiobook")
      assert html =~ ~s("duration": "PT1H15M")
    end

    test "the publisher rides the identity block, right under year and medium", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      post.review
      |> Ecto.Changeset.change(%{publisher: "Addison-Wesley"})
      |> Repo.update!()

      doc = conn |> get(Posts.path(post)) |> html_response(200) |> LazyHTML.from_document()

      # It is a line of the same paragraph as the author and the year · medium
      # line (a `block` span), so it sits directly below them instead of
      # opening a new spaced-out paragraph.
      publisher =
        doc |> LazyHTML.query("[data-review-card] [data-review-meta] + [data-review-publisher]")

      assert LazyHTML.text(publisher) =~ "Publisher: Addison-Wesley"
      assert LazyHTML.attribute(publisher, "class") == ["block"]
    end

    test "the outbound links form their own full-width row", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)
      store_cover!(post.review)

      post.review |> Ecto.Changeset.change(%{pages: 448}) |> Repo.update!()

      post.review |> Ecto.Changeset.change(%{duration_minutes: 440}) |> Repo.update!()

      doc = conn |> get(Posts.path(post)) |> html_response(200) |> LazyHTML.from_document()

      # A direct child of the card, below the cover + identity row: where to go
      # next, on one line running the card's full width. The facts themselves
      # (ISBN, running time) now read beside the cover, so this row is links only.
      links = LazyHTML.query(doc, "[data-review-card] > [data-review-links]")
      text = LazyHTML.text(links)

      assert text =~ "Open Library"
      assert text =~ "Amazon"
      refute text =~ "978-3-16-148410-0"
      refute text =~ "7 h 20 min"

      # And the links stay out of the identity column beside the cover.
      identity = LazyHTML.text(LazyHTML.query(doc, "[data-review-card] [data-review-identity]"))
      refute identity =~ "Open Library"
    end

    test "the author reads directly under the title, named as the author", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      doc = conn |> get(Posts.path(post)) |> html_response(200) |> LazyHTML.from_document()

      # Nothing between the two lines: the title paragraph drops the legacy
      # 15px paragraph margin (`mb-0`), so the author sits right under the work
      # it belongs to instead of across a blank line.
      title = LazyHTML.query(doc, "[data-review-card] [data-review-title]")

      assert LazyHTML.attribute(title, "class") == [
               "mb-0 line-clamp-2 font-semibold text-slate-900 dark:text-slate-100"
             ]

      # And the name is labelled, so a line that is neither the title nor the
      # publisher cannot be mistaken for either.
      creator = LazyHTML.query(doc, "[data-review-card] [data-review-creator]")
      assert LazyHTML.text(creator) =~ "by: Martin Fowler"
    end

    test "an audiobook's running time rides the medium word", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      post.review
      |> Ecto.Changeset.change(%{duration_minutes: 440})
      |> Repo.update!()

      doc = conn |> get(Posts.path(post)) |> html_response(200) |> LazyHTML.from_document()

      meta =
        doc
        |> LazyHTML.query("[data-review-card] [data-review-meta]")
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      # How long the recording runs answers the medium, so it reads in
      # parentheses right behind it — not as a line of its own further down.
      assert meta == "2018 · Audiobook (7 h 20 min)"

      # The parenthetical is not part of the Audible link — only the word is.
      assert LazyHTML.text(LazyHTML.query(doc, "[data-review-meta] a")) == "Audiobook"
    end

    test "the ISBN reads in small type beside the cover", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      doc = conn |> get(Posts.path(post)) |> html_response(200) |> LazyHTML.from_document()
      isbn = LazyHTML.query(doc, "[data-review-card] [data-review-identity] [data-review-isbn]")

      # A catalogue number nobody reads at a glance: it belongs with the other
      # facts about the edition, one size down from them.
      assert LazyHTML.text(isbn) =~ "ISBN 978-3-16-148410-0"
      assert hd(LazyHTML.attribute(isbn, "class")) =~ "text-xs"
    end

    test "a very long title and creator are cut to two lines, in full on hover", %{conn: conn} do
      user = insert_activated_user()
      long = "Refactoring — Wie Sie das Design bestehender Software verbessern. Mit einem Vorwort"
      authors = "Martin Fowler, Kent Beck, John Brant, William Opdyke und Don Roberts"

      post =
        create_post!(user, %{
          body: "Sehr lesenswert.",
          review: %{"kind" => "book", "title" => long, "creator" => authors}
        })

      doc = conn |> get(Posts.path(post)) |> html_response(200) |> LazyHTML.from_document()
      title = LazyHTML.query(doc, "[data-review-card] [data-review-title]")
      creator = LazyHTML.query(doc, "[data-review-card] [data-review-creator]")

      # Two lines is the ceiling for both; the whole string stays reachable on
      # hover (and in the agent formats), so nothing is lost by cutting it.
      assert LazyHTML.attribute(title, "class") == [
               "mb-0 line-clamp-2 font-semibold text-slate-900 dark:text-slate-100"
             ]

      assert LazyHTML.attribute(title, "title") == [long]

      # `line-clamp-2` brings its own `display`, so the creator carries no
      # second display utility that could win the cascade over it.
      assert LazyHTML.attribute(creator, "class") == ["line-clamp-2"]
      assert LazyHTML.attribute(creator, "title") == [authors]
    end

    test "the page count sits under the cover, not in the facts row", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)
      store_cover!(post.review)

      post.review |> Ecto.Changeset.change(%{pages: 448}) |> Repo.update!()

      doc = conn |> get(Posts.path(post)) |> html_response(200) |> LazyHTML.from_document()

      # It belongs to the cover: how thick the book is, right under the picture
      # of it, small — not another line competing with the title block or the
      # catalogue facts.
      assert LazyHTML.text(LazyHTML.query(doc, "[data-review-cover] [data-review-pages]")) =~
               "448 pages"

      refute LazyHTML.text(LazyHTML.query(doc, "[data-review-card] [data-review-details]")) =~
               "448 pages"

      refute LazyHTML.text(LazyHTML.query(doc, "[data-review-card] [data-review-identity]")) =~
               "448 pages"
    end

    test "a printed book's page count carries no edition marker", %{conn: conn} do
      user = insert_activated_user()

      post =
        create_post!(user, %{
          body: "Sehr lesenswert.",
          review: %{
            "kind" => "book",
            "identifier" => "978-3-16-148410-0",
            "title" => "Refactoring",
            "medium" => "print"
          }
        })

      post.review |> Ecto.Changeset.change(%{pages: 448}) |> Repo.update!()

      html = conn |> get(Posts.path(post)) |> html_response(200)

      assert html =~ "448 pages"
      refute html =~ "print edition"
    end

    test "the card renders the same at every resolution", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      html = conn |> get(Posts.path(post)) |> html_response(200)

      # Where the card SITS is responsive (an aside from `md` up); what it
      # SHOWS is not — no element inside it may change size, split a line or
      # drop out at a breakpoint, so a phone and a desktop read the identical
      # card.
      responsive =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("[data-review-card] [class]")
        |> LazyHTML.attribute("class")
        |> Enum.flat_map(&String.split/1)
        |> Enum.filter(&(&1 =~ ~r/^(sm|md|lg|xl|2xl|max-\w+):/))

      assert responsive == [],
             "the review card's content varies by breakpoint: #{inspect(responsive)}"
    end

    test "the shop link is labelled with just the store name", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      html = conn |> get(Posts.path(post)) |> html_response(200)

      # Just "Amazon" (the store), not a verbose "View on Amazon ↗".
      assert html =~ ">Amazon</a>"
      refute html =~ "View on Amazon"
    end

    test "the author gets its own line above year and medium, at every width", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      html = conn |> get(Posts.path(post)) |> html_response(200)

      # The creator keeps the first line and the year · medium wrapper sits on
      # the line below it — the aside reading, now the only one, so a long
      # author name never crowds the small facts at any width.
      assert html =~ "Martin Fowler"
      assert html =~ ~s(class="block" data-review-meta)
      assert html =~ "2018"
      assert html =~ "Audiobook"
    end

    test "an audiobook links the medium word to Audible", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      html = conn |> get(Posts.path(post)) |> html_response(200)

      # Only the "Audiobook" word is the link (a search for the book on
      # Audible), not the whole year · medium line.
      assert html =~
               ~r{href="https://www\.audible\.de/search\?keywords=Refactoring\+Martin\+Fowler"[^>]*>\s*Audiobook\s*</a>}
    end

    test "every outbound link on a review card shares one style", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)
      # A fetched cover brings the Open Library link out too, so all three
      # (medium → Audible, Open Library, store) render together.
      store_cover!(post.review)

      html = conn |> get(Posts.path(post)) |> html_response(200)

      classes =
        Regex.scan(
          ~r/<a [^>]*href="[^"]*(?:audible\.de|openlibrary\.org|amazon\.de)[^"]*"[^>]*class="([^"]*)"/,
          html
        )
        |> Enum.map(&List.last/1)

      assert length(classes) == 3
      # No odd-one-out underline: one identical class across all three links.
      assert classes |> Enum.uniq() |> length() == 1
    end

    test "shows the ISBN hyphenated the way it is printed on the book", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      html = conn |> get(Posts.path(post)) |> html_response(200)

      # The stored value is the bare 13 digits (and stays that way in the
      # machine formats — the JSON-LD assertion above); only the reader sees
      # the split form.
      assert html =~ "978-3-16-148410-0"
      refute html =~ "ISBN 9783161484100"
    end

    test "links to the book on Open Library under a cover it fetched", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)
      store_cover!(post.review)

      html = conn |> get(Posts.path(post)) |> html_response(200)

      # The link reads as the book link it is ("Open Library", the twin of the
      # Amazon link) and points at the book's own Open Library page; it still
      # credits the source of the quoted cover (§ 63 UrhG), just without the
      # old "Cover:" caption.
      assert html =~ "/review_covers/#{post.review.id}/"
      assert html =~ ">Open Library</a>"
      assert html =~ "https://openlibrary.org/isbn/9783161484100"
      refute html =~ "Cover: Open Library"

      # Both links sit on one dot-separated line, Open Library first.
      assert html =~ ~r/>Open Library<\/a>.{0,200}\x{00B7}.{0,200}>Amazon<\/a>/s
    end

    test "names no source when there is no cover to credit", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      html = conn |> get(Posts.path(post)) |> html_response(200)

      refute html =~ "Open Library"
    end

    test "lays the card out beside the prose on a wide screen", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      html = conn |> get(Posts.path(post)) |> html_response(200)

      # One column on a phone (the card follows the prose in the DOM), a
      # narrow right-hand aside from `md` up (portrait tablets and small
      # laptop windows included, not just wide desktops).
      assert html =~ "md:flex md:items-start md:gap-4"
      assert html =~ ~s(data-review-aside="true")
    end

    test "a review post with no prose keeps the card full width", %{conn: conn} do
      user = insert_activated_user()
      image = insert(:post_image, user: user, post: nil, token: "reviewtok")

      # A photo-only post is the one way a review can arrive without prose
      # (a post needs a body or an image).
      post =
        create_post!(user, %{
          body: "",
          image_ids: [image.id],
          review: %{"kind" => "book", "title" => "Nur der Kasten"}
        })

      html = conn |> get(Posts.path(post)) |> html_response(200)

      # Nothing to sit beside, so no aside — a 2/5 card in an empty row
      # would just look broken.
      assert html =~ "data-review-card"
      refute html =~ ~s(data-review-aside="true")
    end

    test "renders in German for German visitors (locale dimension)", %{conn: conn} do
      user = insert_activated_user()
      post = reviewed_post!(user)

      post.review
      |> Ecto.Changeset.change(%{publisher: "Addison-Wesley", pages: 448, duration_minutes: 440})
      |> Repo.update!()

      html =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(Posts.path(post))
        |> html_response(200)

      assert html =~ "Hörbuch"
      assert html =~ "von: Martin Fowler"
      assert html =~ "(7 Std. 20 Min.)"
      assert html =~ "Verlag: Addison-Wesley"
      assert html =~ "448 Seiten"
    end
  end

  describe "GET the permalink" do
    test "renders a public post to anonymous visitors, indexable", %{conn: conn} do
      user = insert_activated_user()
      post = create_post!(user, %{body: "Hello **world**", tags: "elixir"})

      conn = get(conn, Posts.path(post))

      assert html_response(conn, 200) =~ "<strong>world</strong>"
      assert conn.resp_body =~ "elixir"
      assert get_resp_header(conn, "x-robots-tag") == []
    end

    test "an inline-referenced attachment renders in place; the rest stays in the gallery", %{
      conn: conn
    } do
      user = insert_activated_user()
      ref = insert(:post_image, user: user, post: nil, token: "reftok", alt: "A chart")
      gal = insert(:post_image, user: user, post: nil, token: "galtok", alt: "Extra")

      post =
        create_post!(user, %{
          body: "See the chart:\n\n![](/post_images/reftok/feed.avif#left)",
          image_ids: [ref.id, gal.id]
        })

      conn = get(conn, Posts.path(post))
      html = html_response(conn, 200)

      # The referenced image renders inline with its alignment modifier…
      assert html =~ ~s(class="post-inline-image post-inline-image--left")
      # …exactly once (de-duplicated out of the gallery below the body)…
      assert length(String.split(html, "/post_images/reftok/feed.avif")) == 2
      # …while the unreferenced attachment still shows as a gallery tile.
      assert html =~ "/post_images/galtok/feed.avif"
    end

    test "full mode lists the tags at the end of the text, not below the gallery", %{conn: conn} do
      user = insert_activated_user()
      ref = insert(:post_image, user: user, post: nil, token: "tagreftok")
      gal = insert(:post_image, user: user, post: nil, token: "taggaltok")

      post =
        create_post!(user, %{
          body: "Text with ![](/post_images/tagreftok/feed.avif#right) a floated picture.",
          tags: "elixir",
          image_ids: [ref.id, gal.id]
        })

      html = html_response(get(conn, Posts.path(post)), 200)

      # The tag chips sit inside the body flow (right after the text, beside a
      # floated image), so they must come BEFORE the gallery markup — a tall
      # float used to push them below the whole image instead.
      tag_pos = :binary.match(html, ~s(href="/tags/elixir")) |> elem(0)
      gallery_pos = :binary.match(html, "/post_images/taggaltok/feed.avif") |> elem(0)
      assert tag_pos < gallery_pos
    end

    test "a photo-only post (empty body) still shows its tags", %{conn: conn} do
      user = insert_activated_user()
      image = insert(:post_image, user: user, post: nil, token: "phototok")

      post = create_post!(user, %{body: "", tags: "elixir", image_ids: [image.id]})

      html = html_response(get(conn, Posts.path(post)), 200)
      assert html =~ ~s(href="/tags/elixir")
    end

    test "a pending inline image is held from strangers but shown to its author", %{conn: conn} do
      {author_conn, author} = create_and_login_user(fresh_conn())

      image =
        insert(:post_image, user: author, post: nil, token: "pendtok", moderation: "pending")

      post =
        create_post!(author, %{
          body: "Fresh:\n\n![](/post_images/pendtok/feed.avif)",
          image_ids: [image.id]
        })

      # Anonymous: no <img> points at the unreleased picture — the body shows
      # no inline image and the gallery shows the neutral placecard. (The raw
      # Markdown source still carries the reference — JSON-LD articleBody and
      # the .md sibling serve the source verbatim — but the bytes behind the
      # unguessable URL stay proxy-gated until the scan releases them.)
      html = html_response(get(conn, Posts.path(post)), 200)
      refute html =~ "post-inline-image"
      refute html =~ ~s(src="/post_images/pendtok)
      assert html =~ "data-image-placecards"

      # The author keeps seeing their own picture inline while it is checked.
      author_html = html_response(get(author_conn, Posts.path(post)), 200)
      assert author_html =~ ~s(class="post-inline-image")
      assert author_html =~ "/post_images/pendtok/feed.avif"
    end

    test "a mid-thread reply's permalink renders the whole conversation (issue #1006)", %{
      conn: conn
    } do
      author = insert_activated_user()
      replier = insert_activated_user()
      root = create_post!(author, %{body: "the conversation root"})
      {:ok, focus} = Posts.create_reply(replier, root, %{body: "the focused answer"})
      {:ok, _nested} = Posts.create_reply(author, focus, %{body: "a deeper answer"})
      {:ok, _sibling} = Posts.create_reply(author, root, %{body: "a sibling branch"})

      html = html_response(get(conn, Posts.path(focus)), 200)

      # The whole thread is on the page: the root above, the deeper answer and
      # the sibling branch below.
      assert html =~ "the conversation root"
      assert html =~ "the focused answer"
      assert html =~ "a deeper answer"
      assert html =~ "a sibling branch"

      # The permalinked post is the highlighted anchor and, having context
      # above it, marked for the arrival auto-scroll.
      assert html =~ ~s(id="thread-focus")
      assert html =~ "data-thread-scroll"

      # Every card hangs under the post it answers, so no card needs a
      # "Replying to" banner to correct the nesting.
      refute html =~ "Replying to"
    end

    # The production report behind issue #1027: in a long branching thread the
    # newest reply was written hours after a busy branch point, so a flat
    # chronological chain put it under a stranger's post and it read as
    # answering that one.
    test "a branching thread nests each reply under the post it answers", %{conn: conn} do
      author = insert_activated_user()
      other = insert_activated_user()
      root = create_post!(author, %{body: "the conversation root"})
      {:ok, alpha} = Posts.create_reply(other, root, %{body: "alpha branch"})
      {:ok, beta} = Posts.create_reply(author, root, %{body: "beta branch"})
      {:ok, _under_beta} = Posts.create_reply(other, beta, %{body: "answer under beta"})
      {:ok, late} = Posts.create_reply(author, alpha, %{body: "the late answer"})

      # Only the conversation card, so the page's own <meta> excerpt of the
      # permalinked post cannot pass for its position in the thread.
      html =
        conn
        |> get(Posts.path(late))
        |> html_response(200)
        |> String.split(~s(id="post-thread"), parts: 2)
        |> List.last()

      # Reading order follows the reply tree: the late answer sits right under
      # the branch it answers, ahead of the whole beta branch it has nothing to
      # do with — not at the bottom where the clock would have put it.
      assert position(html, "alpha branch") < position(html, "the late answer")
      assert position(html, "the late answer") < position(html, "beta branch")
      assert position(html, "beta branch") < position(html, "answer under beta")

      # The branch point (root answered twice) keeps the spine running past the
      # first branch's subtree: an earlier sibling draws the full-height line
      # plus its own tick, only the last one closes with the rounded elbow.
      assert html =~ "h-full w-0.5 rounded-full bg-slate-200"
      assert html =~ "rounded-bl-xl"
    end

    # Past the indent cap every card sits in its parent's column, so nesting
    # can no longer show who answered whom — the banner takes that job back.
    test "a branch below the indent cap names the post it answers", %{conn: conn} do
      author = insert_activated_user()
      brancher = insert_activated_user(first_name: "Bea", last_name: "Brancher")

      # root(0) → r1(1) → r2(2), both of whose answers render past the cap.
      root = create_post!(author, %{body: "capped root"})
      {:ok, r1} = Posts.create_reply(author, root, %{body: "first step"})
      {:ok, r2} = Posts.create_reply(brancher, r1, %{body: "second step"})
      {:ok, _first} = Posts.create_reply(author, r2, %{body: "the first answer"})
      {:ok, second} = Posts.create_reply(author, r2, %{body: "the second answer"})

      html = html_response(get(conn, Posts.path(second)), 200)

      # The first answer follows its parent card directly, so it needs no
      # banner; the second one follows its sibling instead and names the
      # author it really answers.
      assert html =~ "Replying to @#{brancher.username}"
    end

    test "the root's permalink shows its thread without the auto-scroll marker", %{conn: conn} do
      author = insert_activated_user()
      root = create_post!(author, %{body: "root of it all"})

      {:ok, _reply} =
        Posts.create_reply(insert_activated_user(), root, %{body: "an answer below"})

      html = html_response(get(conn, Posts.path(root)), 200)

      assert html =~ "an answer below"
      assert html =~ ~s(id="thread-focus")
      # Nothing above the root, so no scroll jump on arrival.
      refute html =~ "data-thread-scroll"
    end

    test "a post without replies renders standalone, no thread frame", %{conn: conn} do
      post = create_post!(insert_activated_user(), %{body: "all alone here"})

      html = html_response(get(conn, Posts.path(post)), 200)

      assert html =~ "all alone here"
      refute html =~ ~s(id="post-thread")
      refute html =~ "thread-focus"
    end

    test "redirects non-canonical URLs to the canonical form", %{conn: conn} do
      user = insert_activated_user()
      post = create_post!(user, %{body: "x"})

      # The permalink is the post id under the author archive.
      assert Posts.path(post) == "/#{user.username}/posts/#{post.id}"

      # An uppercase UUID still resolves and 302s to the canonical
      # (lowercase) form.
      shouty = "/#{user.username}/posts/#{String.upcase(post.id)}"
      assert redirected_to(get(conn, shouty)) == Posts.path(post)
    end

    test "404s for unknown ids, garbage segments and other authors' posts", %{conn: conn} do
      user = insert_activated_user()
      other = insert_activated_user()
      post = create_post!(other, %{body: "not under this slug"})

      assert get(conn, "/#{user.username}/posts/#{Vutuv.UUIDv7.generate()}").status == 404
      assert get(conn, "/#{user.username}/posts/not-a-uuid-or-year").status == 404
      # A post resolves only under its author's slug.
      assert get(conn, "/#{user.username}/posts/#{post.id}").status == 404
    end

    # The member's AI choice covers their posts: the permalink page and its
    # agent-format siblings both carry the noai directives and the matching
    # Content-Signal, while staying searchable.
    test "an AI-opted-out author's post serves with the noai directives", %{conn: conn} do
      user = insert_activated_user(noai?: true)
      post = create_post!(user, %{body: "human readers welcome"})

      conn = get(conn, Posts.path(post))
      assert html_response(conn, 200) =~ "human readers welcome"
      assert get_resp_header(conn, "x-robots-tag") == ["noai, noimageai"]

      doc = get(fresh_conn(), Posts.path(post) <> ".md")
      assert doc.status == 200
      assert get_resp_header(doc, "content-signal") == ["ai-train=no, search=yes, ai-input=no"]
      assert get_resp_header(doc, "x-robots-tag") == ["noai, noimageai"]
    end

    test "restricted post: 404 for denied readers, 200 + noindex for permitted", %{conn: conn} do
      user = insert_activated_user()
      post = create_post!(user, %{body: "members only", denials: [%{"wildcard" => "logged_out"}]})

      assert get(conn, Posts.path(post)).status == 404

      {member_conn, _member} = create_and_login_user(conn)
      conn = get(member_conn, Posts.path(post))

      assert html_response(conn, 200) =~ "members only"
      # A page-level restriction covers both axes: out of search results
      # and out of AI corpora, whatever the author's own settings say.
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, noai, noimageai"]
    end

    test "followers-only post: teaser for non-followers, post for followers", %{conn: conn} do
      user = insert_activated_user()

      post =
        create_post!(user, %{
          body: "for my people",
          denials: [%{"wildcard" => "non_followers"}]
        })

      # Anonymous: teaser with a login affordance.
      teaser = get(conn, Posts.path(post))
      assert html_response(teaser, 200) =~ "followers of"
      refute teaser.resp_body =~ "for my people"

      # Logged-in non-follower: teaser with a follow button (a POST to the
      # follow route).
      {visitor_conn, _visitor} = create_and_login_user(fresh_conn())
      teaser = get(visitor_conn, Posts.path(post))
      assert html_response(teaser, 200) =~ "followers of"
      assert teaser.resp_body =~ "/follows"
      refute teaser.resp_body =~ "for my people"

      # Follower: the actual post.
      {follower_conn, follower} = create_and_login_user(fresh_conn(), @other_login_attrs)
      insert(:follow, follower: follower, followee: user)
      shown = get(follower_conn, Posts.path(post))
      assert html_response(shown, 200) =~ "for my people"
    end

    test "a frozen followers-only post 404s instead of showing the teaser", %{conn: conn} do
      user = insert_activated_user()

      post =
        create_post!(user, %{
          body: "for my people",
          denials: [%{"wildcard" => "non_followers"}]
        })

      # Moderation froze the post itself (the author's account is fine, so the
      # permalink is still reachable). The teaser must not stand in for it —
      # following can't unlock a frozen post and the tombstone would leak its
      # existence during the case.
      {:ok, _} =
        post
        |> Ecto.Changeset.change(frozen_at: NaiveDateTime.utc_now(:second))
        |> Vutuv.Repo.update()

      # Anonymous, logged-in non-follower, and an existing follower all 404.
      anon = get(conn, Posts.path(post))
      assert anon.status == 404
      refute anon.resp_body =~ "followers of"

      {follower_conn, follower} = create_and_login_user(fresh_conn())
      insert(:follow, follower: follower, followee: user)
      shown = get(follower_conn, Posts.path(post))
      assert shown.status == 404
      refute shown.resp_body =~ "for my people"
    end

    test "every other denial shape is a plain 404, never a teaser", %{conn: conn} do
      user = insert_activated_user()
      other = insert_activated_user()

      post =
        create_post!(user, %{
          body: "x",
          denials: [%{"wildcard" => "non_followers"}, %{"denied_user_id" => other.id}]
        })

      conn = get(conn, Posts.path(post))
      assert conn.status == 404
      refute conn.resp_body =~ "followers of"
    end

    test "the deny list shows to the author and never to other readers" do
      {author_conn, author} = create_and_login_user(fresh_conn())
      denied = insert_activated_user(first_name: "Verboten", last_name: "Mensch")
      post = create_post!(author, %{body: "visible", denials: [%{"denied_user_id" => denied.id}]})

      own_view = get(author_conn, Posts.path(post))
      assert html_response(own_view, 200) =~ "Hidden from"
      assert own_view.resp_body =~ "Verboten"

      # A permitted other reader (logged-in, not the denied user) sees the post
      # but neither the summary nor the denied name.
      {reader_conn, _reader} = create_and_login_user(fresh_conn(), @other_login_attrs)
      reader_view = get(reader_conn, Posts.path(post))
      assert html_response(reader_view, 200) =~ "visible"
      refute reader_view.resp_body =~ "Hidden from"
      refute reader_view.resp_body =~ "Verboten"
    end
  end

  describe "the permalink's other-formats card" do
    test "a public post links to its agent siblings", %{conn: conn} do
      user = insert_activated_user()
      post = create_post!(user, %{body: "shareable"})

      body = get(conn, Posts.path(post)) |> html_response(200)

      assert body =~ ~s(id="post-other-formats")
      assert body =~ ~s(href="#{Posts.path(post)}.md")
      assert body =~ ~s(href="#{Posts.path(post)}.json")
      # A feed has a vCard sibling on the profile, a post never does.
      refute body =~ ~s(href="#{Posts.path(post)}.vcf")
    end

    test "a restricted post shows no card — its anonymous siblings would 404", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "members only", denials: [%{"wildcard" => "logged_out"}]})

      # The owner can see the post itself, but not an Other-formats card (the
      # .md sibling renders the anonymous view, which 404s for a restricted post).
      body = get(conn, Posts.path(post)) |> html_response(200)
      assert body =~ "members only"
      refute body =~ ~s(id="post-other-formats")
    end
  end

  describe "the author's ⋯ menu on the post card" do
    test "the author sees Edit and Delete on the permalink and in the archive" do
      {author_conn, author} = create_and_login_user(fresh_conn())
      post = create_post!(author, %{body: "my words"})

      # The archive renders timeline entries, so its card ids carry the
      # entry id; the permalink shows the bare post.
      for {path, menu_id} <- [
            {Posts.path(post), "post-menu-#{post.id}"},
            {"/#{author.username}/posts", "post-menu-post-#{post.id}"}
          ] do
        html = html_response(get(author_conn, path), 200)

        assert html =~ ~s(id="#{menu_id}")
        assert html =~ ~s(href="/posts/#{post.id}/edit")
        assert html =~ ~s(data-method="delete")
        assert html =~ "Delete this post permanently?"
      end
    end

    test "the permalink shows the action bar with counters to anonymous readers", %{conn: conn} do
      user = insert_activated_user()
      post = create_post!(user, %{body: "counted"})
      for fan <- [insert(:user), insert(:user)], do: :ok = Posts.like_post(fan, post)
      :ok = Posts.repost_post(insert(:user), post)

      html = html_response(get(conn, Posts.path(post)), 200)

      assert html =~ ~s(id="post-actions-#{post.id}-like")
      assert html =~ ~r/data-count="like">\s*2\s*</
      assert html =~ ~r/data-count="repost">\s*1\s*</
    end

    test "the archive lists the author's reposts with the reposted-by line", %{conn: conn} do
      reposter = insert_activated_user(first_name: "Renate", last_name: "Repost")
      original = create_post!(insert_activated_user(), %{body: "originally elsewhere"})
      :ok = Posts.repost_post(reposter, original)

      html = html_response(get(conn, "/#{reposter.username}/posts"), 200)

      assert html =~ "originally elsewhere"
      assert html =~ "Reposted by Renate Repost"
    end

    test "anonymous visitors and other readers get no author menu", %{conn: conn} do
      user = insert_activated_user()
      post = create_post!(user, %{body: "public words"})

      # Anonymous: neither the author menu nor the report menu.
      anonymous = get(conn, Posts.path(post))
      refute html_response(anonymous, 200) =~ "post-menu-#{post.id}"
      refute anonymous.resp_body =~ "post-report-#{post.id}"

      # A logged-in reader gets the quiet report menu, but no Edit/Delete.
      {reader_conn, _reader} = create_and_login_user(fresh_conn(), @other_login_attrs)
      reader_view = get(reader_conn, Posts.path(post))
      refute html_response(reader_view, 200) =~ "post-menu-#{post.id}"
      assert reader_view.resp_body =~ "post-report-#{post.id}"
      assert reader_view.resp_body =~ "/reports/new?"
    end
  end

  describe "GET /:slug/posts (the author archive)" do
    test "lists the author's posts, visibility-filtered per viewer", %{conn: conn} do
      user = insert_activated_user()
      {:ok, _} = Posts.create_post(user, %{body: "open words"})

      {:ok, _} =
        Posts.create_post(user, %{body: "members words", denials: [%{"wildcard" => "logged_out"}]})

      # Anonymous: only the public post.
      anonymous = get(conn, "/#{user.username}/posts")
      assert html_response(anonymous, 200) =~ "open words"
      refute anonymous.resp_body =~ "members words"

      # A logged-in member sees both.
      {member_conn, _member} = create_and_login_user(conn)
      member_view = get(member_conn, "/#{user.username}/posts")
      assert member_view.resp_body =~ "open words"
      assert member_view.resp_body =~ "members words"
    end

    test "404s for unknown authors", %{conn: conn} do
      assert get(conn, "/no-such-user/posts").status == 404
    end

    test "scopes the archive to a year, month or day", %{conn: conn} do
      user = insert_activated_user()
      {:ok, old} = Posts.create_post(user, %{body: "from last year"})
      {:ok, current} = Posts.create_post(user, %{body: "from today"})

      # Posts are stamped with today's UTC date; backdate one for the test.
      Repo.update_all(
        from(p in Vutuv.Posts.Post, where: p.id == ^old.id),
        set: [published_on: ~D[2025-12-31]]
      )

      today = current.published_on

      year_view = get(conn, "/#{user.username}/posts/2025")
      assert html_response(year_view, 200) =~ "from last year"
      refute year_view.resp_body =~ "from today"

      month_view = get(conn, "/#{user.username}/posts/#{today.year}/#{pad(today.month)}")
      assert month_view.resp_body =~ "from today"
      refute month_view.resp_body =~ "from last year"

      day_view = get(conn, "/#{user.username}/posts/2025/12/31")
      assert day_view.resp_body =~ "from last year"
      refute day_view.resp_body =~ "from today"

      empty_view = get(conn, "/#{user.username}/posts/2024")
      assert html_response(empty_view, 200) =~ "Nothing here yet."
    end

    test "scoped pages carry the trail back up the hierarchy", %{conn: conn} do
      user = insert_activated_user()
      {:ok, post} = Posts.create_post(user, %{body: "crumbed"})
      date = post.published_on

      conn =
        get(conn, "/#{user.username}/posts/#{date.year}/#{pad(date.month)}/#{pad(date.day)}")

      assert conn.resp_body =~ "All posts"
      assert conn.resp_body =~ ~s(href="/#{user.username}/posts")
      assert conn.resp_body =~ ~s(href="/#{user.username}/posts/#{date.year}")

      assert conn.resp_body =~
               ~s(href="/#{user.username}/posts/#{date.year}/#{pad(date.month)}")
    end

    test "404s for nonsense period segments", %{conn: conn} do
      user = insert_activated_user()

      assert get(conn, "/#{user.username}/posts/abcd").status == 404
      assert get(conn, "/#{user.username}/posts/2026/13").status == 404
      assert get(conn, "/#{user.username}/posts/2026/02/30").status == 404
    end

    test "?type= filters the archive by entry kind (issue #945)", %{conn: conn} do
      author = insert_activated_user()
      stranger = insert_activated_user()
      {:ok, parent} = Posts.create_post(stranger, %{body: "stranger topic"})
      {:ok, shared} = Posts.create_post(stranger, %{body: "worth resharing"})
      {:ok, _own} = Posts.create_post(author, %{body: "my own post"})
      {:ok, _reply} = Posts.create_reply(author, parent, %{body: "my reply here"})
      :ok = Posts.repost_post(author, shared)

      own = get(conn, "/#{author.username}/posts?type=posts").resp_body
      assert own =~ "my own post"
      refute own =~ "my reply here"
      refute own =~ "worth resharing"

      reposts = get(conn, "/#{author.username}/posts?type=reposts").resp_body
      assert reposts =~ "worth resharing"
      refute reposts =~ "my own post"

      replies = get(conn, "/#{author.username}/posts?type=replies").resp_body
      assert replies =~ "my reply here"
      refute replies =~ "my own post"

      # A bogus type falls back to the full archive.
      all = get(conn, "/#{author.username}/posts?type=bogus").resp_body
      assert all =~ "my own post"
      assert all =~ "worth resharing"
    end

    test "the tab bar shows on the unscoped archive but not on a scoped period", %{conn: conn} do
      user = insert_activated_user()
      {:ok, _} = Posts.create_post(user, %{body: "any post"})

      unscoped = get(conn, "/#{user.username}/posts").resp_body
      assert unscoped =~ ~s(id="archive-post-filter")

      scoped = get(conn, "/#{user.username}/posts/#{Vutuv.BerlinTime.today().year}").resp_body
      refute scoped =~ ~s(id="archive-post-filter")
    end

    test "the agent-format siblings ignore ?type= (stay the whole archive)", %{conn: conn} do
      author = insert_activated_user()
      {:ok, _own} = Posts.create_post(author, %{body: "alpha original"})
      {:ok, shared} = Posts.create_post(insert_activated_user(), %{body: "beta shared"})
      :ok = Posts.repost_post(author, shared)

      # ?type=posts would drop the repost in HTML, but the .json archive is one
      # canonical document and lists every entry regardless of the query.
      json = get(conn, "/#{author.username}/posts.json?type=posts").resp_body
      assert json =~ "alpha original"
      assert json =~ "beta shared"
    end
  end

  describe "the profile's View all link" do
    test "appears only when more posts exist than the profile shows", %{conn: conn} do
      user = insert_activated_user()
      for n <- 1..3, do: {:ok, _} = Posts.create_post(user, %{body: "post #{n}"})

      # The exact archive href (closing quote included): permalinks also
      # start with /posts/ but continue with the post id.
      archive_href = ~s(href="/#{user.username}/posts")

      conn_without = get(conn, "/#{user.username}")
      refute conn_without.resp_body =~ archive_href

      {:ok, _} = Posts.create_post(user, %{body: "post 4"})
      conn_with = get(conn, "/#{user.username}")
      assert conn_with.resp_body =~ archive_href
      assert conn_with.resp_body =~ "View all"
    end
  end

  describe "the reply banner and thread" do
    test "a reply's page shows the parent post itself above it, no redundant banner", %{
      conn: conn
    } do
      parent_author = insert_activated_user(first_name: "Petra", last_name: "Parent")
      parent = create_post!(parent_author, %{body: "original question"})
      {:ok, reply} = Posts.create_reply(insert_activated_user(), parent, %{body: "an answer"})

      html = conn |> get(Posts.path(reply)) |> html_response(200)

      # The conversation view (issue #1006) renders the parent post right
      # above the reply, so the "Replying to" banner would state the obvious
      # twice and stays off for a reply whose parent card sits directly above.
      assert html =~ "original question"
      assert html =~ Posts.path(parent)
      refute html =~ "Replying to @#{parent_author.username}"
    end

    test "after parent deletion the banner names the author's @handle and profile", %{conn: conn} do
      parent_author = insert_activated_user(first_name: "Petra", last_name: "Parent")
      parent = create_post!(parent_author, %{body: "soon gone"})
      {:ok, reply} = Posts.create_reply(insert_activated_user(), parent, %{body: "still here"})

      {:ok, _} = Posts.delete_post(parent)

      html = conn |> get(Posts.path(reply)) |> html_response(200)

      assert html =~ "Reply to a now-deleted post by @#{parent_author.username}"
      refute html =~ "by Petra Parent"
      assert html =~ ~s(href="/#{parent_author.username}")
    end

    test "after the parent author's account deletion the banner is nameless", %{conn: conn} do
      parent_author = insert_activated_user(first_name: "Petra", last_name: "Parent")
      parent = create_post!(parent_author, %{body: "soon gone"})
      {:ok, reply} = Posts.create_reply(insert_activated_user(), parent, %{body: "still here"})

      # The real account-deletion path: the cascade removes the post too.
      Vutuv.Repo.delete!(parent_author)

      html = conn |> get(Posts.path(reply)) |> html_response(200)

      assert html =~ "Reply to a deleted post"
      refute html =~ "Petra Parent"
    end

    test "the parent's page lists visible replies oldest first", %{conn: conn} do
      parent = create_post!(insert_activated_user(), %{body: "the root post"})
      replier = insert_activated_user()

      {:ok, _old} = Posts.create_reply(replier, parent, %{body: "older answer"})

      # A reply inherits the parent's audience now (issue #774); the only way one
      # is hidden from the thread is a moderation freeze.
      {:ok, hidden} =
        Posts.create_reply(insert_activated_user(), parent, %{body: "secret answer"})

      hidden
      |> Ecto.Changeset.change(frozen_at: NaiveDateTime.utc_now(:second))
      |> Vutuv.Repo.update!()

      {:ok, _new} = Posts.create_reply(replier, parent, %{body: "newer answer"})

      html = conn |> get(Posts.path(parent)) |> html_response(200)

      assert html =~ "older answer"
      assert html =~ "newer answer"
      refute html =~ "secret answer"

      {i_old, _} = :binary.match(html, "older answer")
      {i_new, _} = :binary.match(html, "newer answer")
      assert i_old < i_new
    end
  end

  describe "DELETE /posts/:id" do
    test "the author deletes their post", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "bye"})

      conn = delete(conn, "/posts/#{post.id}")

      assert redirected_to(conn) == "/#{user.username}"
      refute Posts.get_post(post.id)
    end

    test "someone else's post 404s and survives", %{conn: conn} do
      other = insert_activated_user()
      post = create_post!(other, %{body: "not yours"})

      {conn, _user} = create_and_login_user(conn)
      assert delete(conn, "/posts/#{post.id}").status == 404
      assert Posts.get_post(post.id)
    end

    test "logged out is redirected away", %{conn: conn} do
      post = create_post!(insert_activated_user(), %{body: "x"})

      conn = delete(conn, "/posts/#{post.id}")
      assert redirected_to(conn) == "/"
      assert Posts.get_post(post.id)
    end
  end
end
