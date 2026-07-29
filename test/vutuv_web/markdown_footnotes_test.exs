defmodule VutuvWeb.MarkdownFootnotesTest do
  @moduledoc """
  Markdown footnotes (issue #1147): `Text[^1].` plus a `[^1]: note` definition
  line renders a superscript reference linked to a numbered note list at the
  end of the body.

  DB-free on purpose (like `markdown_test.exs`): no body here carries an
  `@handle` or a `#hashtag`, so `linkify_entities/1` never reaches the repo.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.Markdown

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  defp render_post(text), do: text |> Markdown.render_post([]) |> Phoenix.HTML.safe_to_string()

  # The anchor ids carry a per-render nonce, so tests match the shape.
  defp ref_id(html) do
    [_, id] = Regex.run(~r/id="(fnref-[0-9A-F]+-1)"/, html)
    id
  end

  defp note_id(html) do
    [_, id] = Regex.run(~r/id="(fn-[0-9A-F]+-1)"/, html)
    id
  end

  describe "rendering" do
    test "a reference and its definition become a linked note" do
      html = render("Ein Satz[^1].\n\n[^1]: Die Anmerkung.")

      assert html =~ ~s(<sup class="footnote-ref")
      assert html =~ ">[1]</a></sup>"
      assert html =~ ~s(class="footnotes")
      assert html =~ "Die Anmerkung."

      # The reference points at the note and the note points back.
      assert html =~ ~s(href="##{note_id(html)}")
      assert html =~ ~s(href="##{ref_id(html)}")
    end

    test "the definition line is lifted out of the prose" do
      html = render("Ein Satz[^1].\n\n[^1]: Die Anmerkung.")

      # No literal footnote source survives anywhere in the output.
      refute html =~ "[^1]"
      refute html =~ "[^1]:"
    end

    test "notes are numbered by first reference, not by definition order" do
      html =
        render("""
        Erst[^b] dann[^a].

        [^a]: Anmerkung A.
        [^b]: Anmerkung B.
        """)

      assert html =~ ">[1]</a></sup>"
      assert html =~ ">[2]</a></sup>"

      # Note 1 is B (referenced first), note 2 is A.
      [_, first_note] = Regex.run(~r/<ol>\s*<li[^>]*>(.*?)<\/li>/s, html)
      assert first_note =~ "Anmerkung B."
      refute first_note =~ "Anmerkung A."
    end

    test "one label referenced twice shares a single note" do
      html = render("Hier[^x] und dort[^x].\n\n[^x]: Einmal.")

      assert html =~ ">[1]</a></sup>"
      refute html =~ ">[2]</a></sup>"
      # Two references, one note.
      assert length(Regex.scan(~r/<sup class="footnote-ref"/, html)) == 2
      assert length(Regex.scan(~r/<li id="fn-/, html)) == 1
    end

    test "the back-link arrow is pinned to its text glyph, not the emoji" do
      # Bare U+21A9 defaults to emoji presentation on macOS/iOS and rendered as a
      # filled grey keycap that read as a button in the middle of the note list.
      html = render("Satz[^1].\n\n[^1]: Die Anmerkung.")

      assert html =~ "&#8617;&#xFE0E;"
    end

    test "a note body renders Markdown and links" do
      html = render("Satz[^1].\n\n[^1]: Siehe **dort**, [Quelle](https://example.com/a).")

      assert html =~ "<strong>dort</strong>"
      assert html =~ ~s(href="https://example.com/a")
      assert html =~ ~s(target="_blank")
    end

    test "a note body of a bare URL is autolinked like any other body" do
      html = render("Satz[^1].\n\n[^1]: https://example.com/quelle")

      assert html =~ ~s(href="https://example.com/quelle")
    end

    test "the footnote anchors stay in the same tab" do
      html = render("Satz[^1].\n\n[^1]: Die Anmerkung.")

      refs = Regex.scan(~r/<a [^>]*href="#[^"]*"[^>]*>/, html)
      assert length(refs) == 2

      for [tag] <- refs do
        refute tag =~ "target=", "an in-page footnote anchor must not open a new tab"
      end
    end

    test "an external link still opens in a new tab" do
      html = render("see [docs](https://hexdocs.pm/phoenix)")
      assert html =~ ~s(target="_blank")
    end
  end

  describe "half-typed syntax stays literal" do
    test "a reference without a definition is left as typed" do
      html = render("Ein Satz[^1] ohne Anmerkung.")

      assert html =~ "[^1]"
      refute html =~ "footnote-ref"
      refute html =~ "footnotes"
    end

    test "a definition nobody references is left as typed" do
      html = render("Ein Satz.\n\n[^1]: Verwaiste Anmerkung.")

      assert html =~ "[^1]:"
      assert html =~ "Verwaiste Anmerkung."
      refute html =~ ~s(class="footnotes")
    end

    test "an empty definition does not create a note" do
      html = render("Ein Satz[^1].\n\n[^1]:")

      assert html =~ "[^1]"
      refute html =~ "footnote-ref"
    end
  end

  describe "code is left alone" do
    test "a reference inside a fenced block is sample text" do
      html = render("```\nSatz[^1].\n\n[^1]: Die Anmerkung.\n```")

      assert html =~ "[^1]"
      refute html =~ "footnote-ref"
      refute html =~ ~s(class="footnotes")
    end

    test "a reference inside an inline code span is sample text" do
      html = render("Die Syntax ist `[^1]` so.\n\n[^1]: Die Anmerkung.")

      assert html =~ "[^1]"
      refute html =~ "footnote-ref"
    end
  end

  describe "the Milkdown escape" do
    test "a backslash-escaped reference and definition still work" do
      # remark (the composer's serializer) escapes `[` in phrasing content, so a
      # body typed in the WYSIWYG can arrive as `\[^1]`. The hook canonicalizes
      # that away at write time; this is the rendering-side guard for anything
      # already stored.
      html = render("Ein Satz\\[^1].\n\n\\[^1]: Die Anmerkung.")

      assert html =~ ~s(<sup class="footnote-ref")
      assert html =~ "Die Anmerkung."
      refute html =~ "\\["
    end
  end

  describe "posts and previews" do
    test "render_post/2 renders footnotes too" do
      html = render_post("Ein Satz[^1].\n\n[^1]: Die Anmerkung.")

      assert html =~ ~s(<sup class="footnote-ref")
      assert html =~ "Die Anmerkung."
    end

    test "a truncated preview keeps the notes its visible text still references" do
      # Two blocks, the first comfortably inside the 1000-character preview
      # budget and the pair well past it, so the cut lands between them.
      long = String.duplicate("Ein langer Absatz über nichts. ", 20)

      source = """
      #{long}Erster Absatz[^1].

      #{long}Zweiter Absatz[^2].

      [^1]: Anmerkung eins.
      [^2]: Anmerkung zwei.
      """

      {safe, truncated?} = Markdown.render_preview(source, [])
      html = Phoenix.HTML.safe_to_string(safe)

      assert truncated?
      assert html =~ ~s(<sup class="footnote-ref")
      assert html =~ "Anmerkung eins."
      # The second paragraph was cut, so its note goes with it.
      refute html =~ "Anmerkung zwei."
      # And nothing dangles as literal source.
      refute html =~ "[^2]"
    end

    test "an untruncated preview keeps every note" do
      {safe, truncated?} =
        Markdown.render_preview("Ein Satz[^1].\n\n[^1]: Die Anmerkung.", [])

      html = Phoenix.HTML.safe_to_string(safe)

      refute truncated?
      assert html =~ "Die Anmerkung."
    end
  end

  describe "plain text" do
    test "flattening keeps the marker and the note text" do
      text = Markdown.to_plain_text("Ein Satz[^1].\n\n[^1]: Die Anmerkung.")

      assert text =~ "Ein Satz[1]."
      assert text =~ "Die Anmerkung."
      refute text =~ "[^1]"
    end
  end

  describe "limits" do
    test "beyond the cap a reference stays literal instead of growing the note list" do
      count = Markdown.Footnotes.max_footnotes() + 5

      refs = Enum.map_join(1..count, " ", &"x[^#{&1}]")
      defs = Enum.map_join(1..count, "\n", &"[^#{&1}]: Anmerkung #{&1}.")
      html = render(refs <> "\n\n" <> defs)

      notes = Regex.scan(~r/<li id="fn-/, html)
      assert length(notes) == Markdown.Footnotes.max_footnotes()
      # The ones past the cap are still visible to their author, as typed.
      assert html =~ "[^#{count}]"
    end
  end
end
