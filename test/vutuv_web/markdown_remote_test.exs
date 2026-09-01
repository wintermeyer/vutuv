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

      # `rel` also carries the ugc/nofollow marking every outbound link in
      # somebody else's post gets (see VutuvWeb.RemoteContentSeoTest).
      assert html =~
               ~s(<a target="_blank" rel="ugc nofollow noopener noreferrer" href="https://drnik.org/tausendfusser.html">)

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

  describe "split_trailing_hashtags/1" do
    # The chips a text comes back with, as `{name, text}` pairs.
    defp tags(text) do
      {body, tags} = Markdown.split_trailing_hashtags(text)
      {body, Enum.map(tags, &{&1.name, &1.text})}
    end

    test "lifts a closing hashtag line off the body" do
      assert tags("Fall Abdul B.\n\nDer Anwalt sagt Report Mainz.\n\n#CSD #Anschlag #Berlin") ==
               {"Fall Abdul B.\n\nDer Anwalt sagt Report Mainz.",
                [{"CSD", "CSD"}, {"Anschlag", "Anschlag"}, {"Berlin", "Berlin"}]}
    end

    test "takes every consecutive closing hashtag line, blank lines and all" do
      assert tags("Ein Text\n\n#eins #zwei\n\n#drei\n") ==
               {"Ein Text", [{"eins", "eins"}, {"zwei", "zwei"}, {"drei", "drei"}]}
    end

    test "a hashtag line in the middle of the text stays where the author put it" do
      text = "Oben\n\n#mitten drin\n\nUnten"

      assert tags(text) == {text, []}
    end

    test "a closing line that is more than hashtags is left alone" do
      text = "Ein Text\n\nMehr zu #Berlin gibt es hier"

      assert tags(text) == {text, []}
    end

    test "a post that is nothing but hashtags becomes pills and an empty body" do
      assert tags("#Crochet #Botanik") ==
               {"", [{"Crochet", "Crochet"}, {"Botanik", "Botanik"}]}
    end

    test "the typed case is kept and a repeat is dropped" do
      assert tags("Text\n\n#Berlin #berlin #BERLIN") == {"Text", [{"Berlin", "Berlin"}]}
    end

    test "text without a closing hashtag line comes back unchanged" do
      assert tags("Nur ein Satz.") == {"Nur ein Satz.", []}
      assert tags("") == {"", []}
    end

    test "a non-ASCII hashtag counts, so a German closing line splits too" do
      assert tags("Text\n\n#München #Grünflächen") ==
               {"Text", [{"München", "München"}, {"Grünflächen", "Grünflächen"}]}
    end

    test "a tag with something glued to its end closes the line and keeps the glue" do
      assert tags("Kommentar\n\n#Kommentar #Russland #Drohnen #FlughafenLeipzig/Halle") ==
               {"Kommentar",
                [
                  {"Kommentar", "Kommentar"},
                  {"Russland", "Russland"},
                  {"Drohnen", "Drohnen"},
                  {"FlughafenLeipzig", "FlughafenLeipzig/Halle"}
                ]}
    end

    test "tags run together in one token become one chip each" do
      assert tags("Text\n\n#Nepal#Rockfall#FlashFlood") ==
               {"Text",
                [{"Nepal", "Nepal"}, {"Rockfall", "Rockfall"}, {"FlashFlood", "FlashFlood"}]}
    end

    test "a closing URL glued to the last tag keeps the whole line in the body" do
      text = "Text\n\n#comic #humor #wortspielhttps://rainking.de/2026/08/16/wok/"

      assert tags(text) == {text, []}
    end

    test "an address glued to a tag keeps the line too" do
      text = "Text\n\n#aborto #Italia #islam@politica@salute"

      assert tags(text) == {text, []}
    end

    test "a token that only carries a hashtag later in it is still prose" do
      text = "Text\n\nFlughafen#Leipzig #Halle"

      assert tags(text) == {text, []}
    end
  end
end
