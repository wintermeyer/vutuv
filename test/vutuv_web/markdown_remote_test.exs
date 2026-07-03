defmodule VutuvWeb.MarkdownRemoteTest do
  # DB-backed (hashtag linking resolves against tags; the mention test needs a
  # real member to prove the handle is deliberately NOT linked).
  use Vutuv.DataCase, async: true

  alias VutuvWeb.Markdown

  defp linkable_tag(slug, name) do
    tag = insert(:tag, name: name, slug: slug)
    insert(:user_tag, user: insert_activated_user(), tag: tag)
    tag
  end

  describe "render_remote/1" do
    test "autolinks bare URLs with truncated display, opening in a new tab" do
      html = Markdown.render_remote("Anleitung: https://drnik.org/tausendfusser.html")

      assert html =~
               ~s(<a target="_blank" rel="noopener noreferrer" href="https://drnik.org/tausendfusser.html">)

      assert html =~ "drnik.org/tausendfusser.html</a>"
    end

    test "keeps the remote truncation ellipsis out of the link target" do
      html = Markdown.render_remote("https://example.org/list…")

      assert html =~ ~s(href="https://example.org/list">)
      refute html =~ ~s(href="https://example.org/list…")
    end

    test "understands Markdown" do
      html = Markdown.render_remote("Ein **fetter** Gruß\n\n- eins\n- zwei")

      assert html =~ "<strong>fetter</strong>"
      assert html =~ "<li>"
    end

    test "links a #hashtag of a non-empty tag; unknown hashtags stay plain text" do
      linkable_tag("crochet", "Crochet")

      html = Markdown.render_remote("Kleine Kritzelei #Crochet #eranthishyemalis")

      assert html =~ ~s(<a href="/tags/crochet" class="hashtag">#Crochet</a>)
      refute html =~ ~s(/tags/eranthishyemalis)
      assert html =~ "#eranthishyemalis"
    end

    test "a #hashtag at the start of a line is a hashtag, not a heading" do
      linkable_tag("botanik", "Botanik")

      html = Markdown.render_remote("#Botanik im Frühling")

      refute html =~ "<h1"
      assert html =~ ~s(<a href="/tags/botanik" class="hashtag">#Botanik</a>)
    end

    test "never links a @mention, even when a member shares the handle" do
      insert_activated_user(username: "poleguy")

      html = Markdown.render_remote("RE: @poleguy hat recht")

      # A Mastodon @name names a fediverse account, not the vutuv member who
      # happens to share the handle.
      refute html =~ ~s(href="/poleguy")
      refute html =~ "class=\"mention\""
      assert html =~ "@poleguy"
    end

    test "images and raw HTML never survive" do
      html =
        Markdown.render_remote("![x](https://evil.example/pix.png) <script>alert(1)</script>")

      refute html =~ "<img"
      refute html =~ "<script"
    end
  end
end
