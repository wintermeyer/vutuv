defmodule VutuvWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias VutuvWeb.Markdown

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  test "renders bold, italics and inline code" do
    html = render("**bold** and _italic_ and `code`")
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<em>italic</em>"
    assert html =~ "<code"
  end

  test "drops images — no message body embeds a picture" do
    html = render("before ![pic](https://evil.example/x.png) after")

    refute html =~ "<img"
    refute html =~ "evil.example"
    assert html =~ "before"
    assert html =~ "after"
  end

  test "renders markdown links opening in a new tab" do
    html = render("see [the docs](https://hexdocs.pm/phoenix)")
    assert html =~ ~s(href="https://hexdocs.pm/phoenix")
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(rel="noopener noreferrer")
    assert html =~ ">the docs</a>"
  end

  test "autolinks bare URLs and shortens the display to host + first path dir" do
    url = "https://en.wikipedia.org/wiki/Elixir_(programming_language)?utm_source=very_long"
    html = render("look at #{url} now")

    # the href is the full URL; the visible text is cut to host + first dir + …
    assert html =~ ~s(href="#{url}")
    assert html =~ ">en.wikipedia.org/wiki/…</a>"
    refute html =~ ">https://en.wikipedia.org"
  end

  # Issue #918: a bare URL with a query string must render as one clean anchor
  # with nothing dangling after it. The store holds bare, unescaped URLs (the
  # editor canonicalizes them — see assets/js/markdown_editor.js), so the
  # renderer just autolinks them; it carries no escaped-URL repair of its own.
  test "autolinks a bare URL with a query string cleanly (no stray characters)" do
    url = "https://www.tagworx.net/ynews.php?cid=1&nid=39010"
    html = render("Weiterlesen unter #{url}")

    assert html =~ ~s(href="https://www.tagworx.net/ynews.php?cid=1&amp;nid=39010")
    # the anchor is the whole match — no leftover ")" or backslash after it
    refute html =~ "</a>)"
    refute html =~ "\\"
  end

  describe "bare URL display" do
    # The visible text of the first autolinked anchor.
    defp link_text(text) do
      html = text |> Markdown.render() |> Phoenix.HTML.safe_to_string()
      [_, inner] = Regex.run(~r{<a[^>]*>([^<]*)</a>}, html)
      inner
    end

    test "drops a leading www." do
      assert link_text("go to https://www.example.com now") == "example.com"
    end

    test "keeps a bare host as-is" do
      assert link_text("go to https://example.com now") == "example.com"
    end

    test "keeps host plus a single path directory" do
      assert link_text("see https://example.com/about here") == "example.com/about"
    end

    test "elides a deeper path after the first directory" do
      assert link_text("see https://www.hostsharing.net/downloads/manual.pdf now") ==
               "hostsharing.net/downloads/…"
    end

    test "ignores a trailing slash after the first directory" do
      assert link_text("see https://example.com/about/ here") == "example.com/about"
    end

    test "char-caps a pathologically long single segment" do
      text = link_text("x https://example.com/" <> String.duplicate("a", 60) <> " y")

      assert String.length(text) <= 40
      assert String.ends_with?(text, "…")
    end
  end

  test "newlines become line breaks" do
    assert render("line one\nline two") =~ "<br"
  end

  test "drops the editor's empty-paragraph <br /> artifacts instead of showing them" do
    # The Milkdown editor serializes each blank line the writer adds as a
    # standalone `<br />` block. Because the pipeline escapes `<`, those would
    # otherwise render as literal "<br />" text (seen on a real post). They
    # collapse to a normal paragraph break.
    html = render("above\n\n<br />\n\n<br />\n\n<br />\n\nbelow")

    refute html =~ "br /&gt;"
    refute html =~ "&lt;br"
    assert html =~ "above"
    assert html =~ "below"
  end

  test "drops the editor's empty-table-cell <br /> artifacts, keeping the table" do
    # Milkdown fills empty table cells with `<br />`; those must not render as
    # literal "<br />" text inside every cell (seen on a real post).
    md = "| a | b |\n| :-- | :-- |\n| <br /> | <br /> |"
    html = render(md)

    refute html =~ "&lt;br"
    assert html =~ "<table"
    assert html =~ "<td"
  end

  test "keeps a literal <br> inside a fenced code block (a code sample, not an artifact)" do
    html = render("```\n<br />\n```")
    assert html =~ "br"
    assert html =~ "<code"
  end

  describe "render_preview/3 truncation" do
    defp preview(text, opts \\ []) do
      {html, truncated?} = Markdown.render_preview(text, [], opts)
      {Phoenix.HTML.safe_to_string(html), truncated?}
    end

    test "short content is rendered whole and not marked truncated" do
      {html, truncated?} = preview("Just a short post.")

      assert html =~ "Just a short post."
      refute truncated?
    end

    test "a one-line intro above a long block keeps part of that block (not just the intro)" do
      intro = "Testing this self-improvement rule for my setup:"
      long = "- " <> String.duplicate("word ", 400)

      {html, truncated?} = preview(intro <> "\n\n" <> long)

      assert truncated?
      assert html =~ "Testing this self-improvement rule"
      # The long block is word-cut into the preview instead of being dropped, so
      # its text and list markup appear — it used to collapse to just the intro.
      assert html =~ "<li>"
      assert html =~ "word word"
    end

    test "an overflowing fenced code block is kept whole rather than cut mid-fence" do
      intro = "Here is the code:"
      fence = "```\n" <> String.duplicate("x = 1\n", 300) <> "```"

      {html, truncated?} = preview(intro <> "\n\n" <> fence)

      assert truncated?
      assert html =~ "Here is the code"
      # Cutting a fence breaks rendering, so it is included whole (the CSS clamp
      # trims it visually) — the preview is never stranded on the intro line.
      assert html =~ "x = 1"
    end
  end

  test "raw HTML shows as literal text and never executes" do
    html = render(~s|<script>alert("x")</script> **safe**|)
    refute html =~ "<script"
    # the typed tag is displayed, escaped
    assert html =~ "&lt;script"
    assert html =~ "<strong>safe</strong>"
  end

  test "strips javascript: links" do
    html = render("[click](javascript:alert(1))")
    refute html =~ "javascript:"
  end

  test "non-binary input renders as empty" do
    assert Phoenix.HTML.safe_to_string(Markdown.render(nil)) == ""
  end

  describe "fediverse handles" do
    # `render/1` is the messages/chat renderer, `render_post/2` the posts
    # renderer; both funnel through the same `linkify_entities` pass, so a
    # single implementation links `@user@host` in DMs and posts alike. These
    # cases stay DB-free: a fediverse handle needs no member lookup.
    defp post_html(text), do: text |> Markdown.render_post([]) |> Phoenix.HTML.safe_to_string()

    test "links a @user@host handle to the remote profile (messages)" do
      html = render("Follow @hostsharing@geno.social for hosting")

      assert html =~ ~s(href="https://geno.social/@hostsharing")
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener noreferrer")
      assert html =~ ">@hostsharing@geno.social</a>"
    end

    test "links the same handle identically in a post (shared with messages)" do
      html = post_html("Follow @hostsharing@geno.social for hosting")

      assert html =~ ~s(href="https://geno.social/@hostsharing")
      assert html =~ ">@hostsharing@geno.social</a>"
    end

    test "never mislinks a two-part handle to a local member profile" do
      html = render("ping @hostsharing@geno.social")

      # Points at the remote account, not the local /hostsharing profile — the
      # user part is not even looked up as a vutuv member.
      assert html =~ ~s(href="https://geno.social/@hostsharing")
      refute html =~ ~s(href="/hostsharing")
    end

    test "lowercases the host but preserves the typed user case" do
      html = render("see @Ada@Geno.Social today")

      assert html =~ ~s(href="https://geno.social/@Ada")
      assert html =~ ">@Ada@Geno.Social</a>"
    end

    test "resolves multi-label hosts (subdomains, multi-part TLDs)" do
      html = render("hi @team@social.example.co.uk")

      assert html =~ ~s(href="https://social.example.co.uk/@team")
    end

    test "leaves trailing sentence punctuation outside the link" do
      html = render("reach me at @a@b.social.")

      assert html =~ ~s(href="https://b.social/@a")
      assert html =~ ">@a@b.social</a>"
      # the final period is part of the sentence, not the handle
      refute html =~ "b.social.</a>"
    end

    test "does not treat an email address as a fediverse handle" do
      html = render("mail me at foo@bar.com please")

      assert html =~ "foo@bar.com"
      refute html =~ "<a"
    end

    test "render_remote links a qualified handle but leaves a bare @name plain" do
      html = Markdown.render_remote("boost from @hostsharing@geno.social cc @localguy")

      assert html =~ ~s(href="https://geno.social/@hostsharing")
      # a bare @name in remote content stays plain text (it is ambiguous)
      refute html =~ ~s(href="/localguy")
    end
  end
end
