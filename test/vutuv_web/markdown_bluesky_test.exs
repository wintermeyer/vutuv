defmodule VutuvWeb.MarkdownBlueskyTest do
  @moduledoc """
  A Bluesky handle `@name.bsky.social` links to that account on bsky.app.

  It is written like a fediverse address and is not one: the whole thing after
  the `@` is a domain, with no second `@` to end the user part. So the shared
  entity grammar read `@hilwiller.bsky.social` as the local member `@hilwiller`
  followed by dead text — which linked a boosted post's Bluesky mention to
  whichever vutuv member happens to hold that handle, and refused to save a
  member's own post naming one ("the handle @hilwiller does not exist").
  """
  # DB-backed: one case proves a real member of that name is not linked to.
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias VutuvWeb.Markdown

  @handle "@hilwiller.bsky.social"
  @profile "https://bsky.app/profile/hilwiller.bsky.social"

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  defp render_post(text), do: text |> Markdown.render_post([]) |> Phoenix.HTML.safe_to_string()

  describe "bluesky handles" do
    test "a message links the handle to bsky.app in a new tab" do
      html = render("Folge #{@handle} für Recherchen")

      assert html =~ ~s(href="#{@profile}")
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener noreferrer")
      assert html =~ ">#{@handle}</a>"
    end

    test "a post links it the same way" do
      html = render_post("Folge #{@handle} für Recherchen")

      assert html =~ ~s(href="#{@profile}")
      assert html =~ ~s(target="_blank")
    end

    test "a boosted remote post links it too, marked ugc nofollow" do
      # The case that brought this up: a Mastodon post naming two Bluesky
      # accounts, drawn as a card in the feed.
      html =
        Markdown.render_remote(
          "#RiffTalk: @hilwiller.bsky.social und @latamreporter.bsky.social sprechen"
        )

      assert html =~ ~s(href="#{@profile}")
      assert html =~ ~s(href="https://bsky.app/profile/latamreporter.bsky.social")
      assert html =~ ~s(rel="ugc nofollow noopener noreferrer")
    end

    test "never links a member who happens to hold the first label" do
      insert(:user, username: "hilwiller", first_name: "Hilde", last_name: "Willer")

      html = render("Folge #{@handle}")

      refute html =~ ~s(href="/hilwiller")
      assert html =~ ~s(href="#{@profile}")
      # and the tail is part of the link, not text stranded beside it
      refute html =~ "</a>.bsky.social"
    end

    test "the href is lowercased, the typed spelling stays the label" do
      html = render("see @Hilwiller.BSky.Social today")

      assert html =~ ~s(href="#{@profile}")
      assert html =~ ">@Hilwiller.BSky.Social</a>"
    end

    test "trailing sentence punctuation stays outside the link" do
      html = render("Mehr bei #{@handle}.")

      assert html =~ ~s(href="#{@profile}")
      assert html =~ ">#{@handle}</a>"
      refute html =~ "social.</a>"
    end

    test "a longer host that only starts like one is left alone" do
      html = render("nichts an @hilwiller.bsky.socialize hier")

      refute html =~ "bsky.app"
      refute html =~ ~s(href="/hilwiller")
    end

    test "a deeper domain under that one is left alone too" do
      # The `\\.?` half of the grammar's trailing guard: `@a.bsky.social.de` is
      # somebody else's domain, not an account on Bluesky.
      html = render("nichts an @hilwiller.bsky.social.de hier")

      refute html =~ "bsky.app"
    end

    test "an email address on that domain is not a handle" do
      html = render("schreib an post@hilwiller.bsky.social bitte")

      refute html =~ "bsky.app"
      assert html =~ "post@hilwiller.bsky.social"
    end

    test "a handle inside code is sample text" do
      html = render("schreib `@hilwiller.bsky.social` so")

      refute html =~ "bsky.app"
    end

    test "a handle inside a URL stays part of that URL's own link" do
      html = render("siehe https://bsky.brid.gy/ap/@hilwiller.bsky.social hier")

      assert html =~ ~s(href="https://bsky.brid.gy/ap/@hilwiller.bsky.social")
      refute html =~ ~s(href="#{@profile}")
    end

    test "a pasted bsky.app link shows whose profile it is" do
      html = render("siehe https://bsky.app/profile/hilwiller.bsky.social")

      assert html =~ ~s(href="#{@profile}")
      assert html =~ ">bsky.app/profile/hilwiller.bsky.social</a>"
    end

    test "a fediverse address on that host is still read as one" do
      # `@ada@bsky.social` names a user part and a host, which is the other
      # grammar — the Bluesky form has no second `@`.
      html = render("hallo @ada@bsky.social")

      assert html =~ ~s(href="https://bsky.social/@ada")
      refute html =~ "bsky.app"
    end
  end

  describe "the composer's copy of the grammar" do
    # `MENTION_RUN` in the editor is the client half of `Vutuv.Mentions`'
    # `@entity`, and nothing fails when the two drift: the composer would chip
    # the `@hilwiller` in front of the dot, spend one of the five mentions a
    # post may carry and ask the server whether that member exists — about a
    # handle the renderer links out instead. There is no JS test runner here,
    # so this is a static source check, like `markdown_editor_link_test.exs`.
    @editor_js Path.expand("../../assets/js/markdown_editor.js", __DIR__)

    test "the mention run excludes a Bluesky handle" do
      js = File.read!(@editor_js)

      assert js =~ ~S(\.bsky\.social),
             "MENTION_RUN in markdown_editor.js must exclude `@name.bsky.social`, or the " <>
               "composer chips a member who merely shares the handle's first label"

      assert js =~ ~s("giu"),
             "the mention run needs the `i` flag to read a shouted host the same way the " <>
               "server's `(?i:…)` does"
    end
  end
end
