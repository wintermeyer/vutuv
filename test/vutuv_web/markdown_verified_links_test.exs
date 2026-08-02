defmodule VutuvWeb.MarkdownVerifiedLinksTest do
  @moduledoc """
  A link in a post that points at a webpage the **author** proved is theirs
  earns the small verified mark (issue #1246).

  The rule lives in `Vutuv.Profiles.VerifiedLinks` and is tested there; this
  covers what the renderer does with the answer — which anchors it touches,
  what it writes into them, and what it leaves alone.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Profiles.Url
  alias VutuvWeb.Markdown

  defp link(value, method \\ "rel_me") do
    %Url{
      id: value,
      value: value,
      description: "Alice's notebook",
      verification_method: method,
      verified_at: ~N[2026-08-01 10:00:00]
    }
  end

  defp render(text, links) do
    text |> Markdown.render_post([], verified_links: links) |> Phoenix.HTML.safe_to_string()
  end

  describe "render_post/3 with the author's verified links" do
    test "marks a bare URL that points at the proven page" do
      html = render("New piece: https://example.com/~alice", [link("https://example.com/~alice")])

      assert html =~ ~s(class="verified-author-link")
      assert html =~ ~s(href="https://example.com/~alice")
      # ...and the mark sits inside the link it belongs to.
      assert html =~ ~r{<a[^>]*>[^<]*<svg class="verified-author-link".*?</svg></a>}s
    end

    test "marks a Markdown link and keeps the author's own anchor text" do
      html =
        render(
          "I wrote [something about bridges](https://example.com/~alice) last night.",
          [link("https://example.com/~alice")]
        )

      assert html =~ ~s(class="verified-author-link")
      assert html =~ "something about bridges"
      # The profile entry's own label is deliberately NOT substituted: the
      # anchor text is the author's words inside their own sentence.
      refute html =~ "Alice's notebook"
    end

    test "names the proven address in the mark's accessible name" do
      html = render("https://example.com/~alice", [link("https://example.com/~alice")])

      assert html =~ ~s|aria-label="Verified webpage of the author (example.com/~alice)"|
      assert html =~ "<title>Verified webpage of the author (example.com/~alice)</title>"
    end

    test "a whole-host proof names the host, not the page that was linked" do
      html =
        render("https://example.com/anywhere/deep", [link("https://example.com/", "dns")])

      assert html =~ ~s|aria-label="Verified webpage of the author (example.com)"|
    end

    test "marks the same page pasted with www., a trailing slash and a tracking query" do
      links = [link("https://example.com/~alice")]

      for pasted <- [
            "https://www.example.com/~alice",
            "https://example.com/~alice/",
            "http://example.com/~alice?utm_source=newsletter"
          ] do
        assert render("Read: #{pasted}", links) =~ ~s(class="verified-author-link"),
               "#{pasted} names the proven page and should be marked"
      end
    end

    test "leaves a link the author never proved alone" do
      html =
        render("https://example.com/~bob", [link("https://example.com/~alice")])

      refute html =~ "verified-author-link"
      assert html =~ ~s(href="https://example.com/~bob")
    end

    test "marks nothing when the author has no verified links" do
      html = render("https://example.com/~alice", [])

      refute html =~ "verified-author-link"
    end

    test "an unverified link marks nothing, even on the very same URL" do
      never_proved = %Url{value: "https://example.com/~alice", verified_at: nil}

      refute render("https://example.com/~alice", [never_proved]) =~ "verified-author-link"
    end

    test "a URL inside an inline code span stays literal text" do
      html =
        render("Fetch it with `https://example.com/~alice`", [link("https://example.com/~alice")])

      refute html =~ "verified-author-link"
      refute html =~ "<a "
    end

    test "a URL inside a fenced code block stays literal text" do
      body = """
      Try it:

      ```sh
      curl https://example.com/~alice
      ```
      """

      html = render(body, [link("https://example.com/~alice")])

      refute html =~ "verified-author-link"
    end

    test "marks every occurrence of the proven page in one body" do
      html =
        render(
          "Here: https://example.com/~alice and again https://example.com/~alice",
          [link("https://example.com/~alice")]
        )

      assert length(String.split(html, "verified-author-link")) == 3
    end

    test "a proven address carrying an @ stays inside the anchor" do
      # The entity linker runs after this pass and skips everything inside an
      # `a`, so an address like example.com/@alice can never be mistaken for a
      # fediverse handle in the mark's own label.
      html =
        Markdown.mark_verified_author_links(
          ~s|<a href="https://example.com/@alice">x</a>|,
          [link("https://example.com/@alice")]
        )

      assert html =~ "verified-author-link"
      assert String.ends_with?(html, "</svg></a>")
    end
  end

  describe "render_preview/3" do
    test "marks the author's verified link in a feed preview too" do
      {safe, _truncated?} =
        Markdown.render_preview("Out now: https://example.com/~alice", [],
          verified_links: [link("https://example.com/~alice")]
        )

      assert Phoenix.HTML.safe_to_string(safe) =~ "verified-author-link"
    end
  end

  describe "mark_verified_author_links/2" do
    test "escapes the proven address, so it cannot break out of the attribute" do
      hostile = %Url{
        id: "hostile",
        value: ~s|https://example.com/a"onmouseover="alert(1)|,
        verification_method: "rel_me",
        verified_at: ~N[2026-08-01 10:00:00]
      }

      html =
        Markdown.mark_verified_author_links(
          ~s|<a href="https://example.com/a&quot;onmouseover=&quot;alert(1)">x</a>|,
          [hostile]
        )

      assert html =~ "verified-author-link"
      refute html =~ ~s|onmouseover="alert|
      assert html =~ "&quot;onmouseover=&quot;"
    end

    test "leaves a same-page footnote anchor alone" do
      html =
        Markdown.mark_verified_author_links(
          ~s|<a href="#fn-1" class="footnote-ref">1</a>|,
          [link("https://example.com/~alice")]
        )

      refute html =~ "verified-author-link"
    end
  end

  describe "verified_author_links/2 — what the agent formats report" do
    test "answers the proven links the body actually points at, without repeats" do
      alice = link("https://example.com/~alice")
      blog = link("https://blog.example/", "dns")

      found =
        Markdown.verified_author_links(
          "Twice: https://example.com/~alice and https://example.com/~alice/ — " <>
            "nothing from https://blog.example/ though",
          [alice, blog]
        )

      assert found == [alice, blog]
    end

    test "ignores a URL that only appears in a code fence" do
      body = "```\nhttps://example.com/~alice\n```"

      assert Markdown.verified_author_links(body, [link("https://example.com/~alice")]) == []
    end

    test "answers [] with no verified links at all" do
      assert Markdown.verified_author_links("https://example.com/~alice", []) == []
    end
  end
end
