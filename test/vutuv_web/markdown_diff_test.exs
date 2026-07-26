defmodule VutuvWeb.MarkdownDiffTest do
  use ExUnit.Case, async: true

  # Issue #1108: a fenced ```diff block used to render as one grey wall of
  # monospace text with the `+`/`-` sitting in the code like any other
  # character, so nothing told an added line from a removed one. Every line is
  # marked up as what it is now, and the marker moves into its own gutter span.
  #
  # The pair of static stylesheet checks at the bottom are in the spirit of
  # `dark_mode_css_test.exs`: the markup alone is invisible, so the rules that
  # colour it — in both schemes — are part of the feature.

  alias VutuvWeb.Markdown

  @components_css Path.expand("../../assets/css/components.css", __DIR__)

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  defp diff_post(body), do: "```diff\n" <> body <> "\n```"

  # The rows of the first diff block, as {kind, marker, code} triples.
  defp rows(html) do
    ~r{<span class="diff-line diff-line--([a-z]+)"><span class="diff-line__marker">([^<]*)</span>(.*?)</span>}
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(&List.to_tuple/1)
  end

  describe "fenced diff blocks" do
    test "marks each line as added, removed or context and guts the +/- out of the code" do
      html =
        """
        <?php
        - $a = 'a';
        + $a = 'z';
        $b = 'b';
        """
        |> String.trim_trailing()
        |> diff_post()
        |> render()

      assert rows(html) == [
               {"context", "", "&lt;?php"},
               {"del", "-", " $a = 'a';"},
               {"add", "+", " $a = 'z';"},
               {"context", "", "$b = 'b';"}
             ]
    end

    test "wraps the block so the stylesheet can find it" do
      html = render(diff_post("+ added"))

      assert html =~ ~s(<pre class="diff-block"><code class="diff">)
    end

    test "keeps the real newlines between the rows, so a copy and the plain-text flattening still read line by line" do
      html = render(diff_post("- old\n+ new"))

      assert html =~ "</span>\n<span"
      assert Markdown.to_plain_text(diff_post("- old\n+ new")) =~ "- old\n+ new"
    end

    test "tells a unified diff's headers and hunk markers from its changed lines" do
      html =
        """
        diff --git a/x.php b/x.php
        index 1234567..89abcde 100644
        --- a/x.php
        +++ b/x.php
        @@ -1,3 +1,3 @@
         $keep = 1;
        -$a = 'a';
        +$a = 'z';
        """
        |> String.trim_trailing()
        |> diff_post()
        |> render()

      assert [
               {"meta", "", "diff --git a/x.php b/x.php"},
               {"meta", "", "index 1234567..89abcde 100644"},
               {"meta", "", "--- a/x.php"},
               {"meta", "", "+++ b/x.php"},
               {"hunk", "", "@@ -1,3 +1,3 @@"},
               {"context", " ", "$keep = 1;"},
               {"del", "-", "$a = 'a';"},
               {"add", "+", "$a = 'z';"}
             ] == rows(html)
    end

    test "renders a blank line inside the diff as an empty row, not a swallowed one" do
      html = render(diff_post("- old\n\n+ new"))

      assert [{"del", _, _}, {"context", "", ""}, {"add", _, _}] = rows(html)
    end

    test "leaves a trailing blank line out instead of ending on a stray empty row" do
      html = render("```diff\n+ added\n\n```")

      assert [{"add", "+", " added"}] = rows(html)
    end

    test "treats a `patch` fence the same" do
      assert render("```patch\n+ added\n```") =~ ~s(diff-line--add)
    end

    # The `elixir` fence is checked on a shorter slice of its own text: it is
    # syntax-highlighted (VutuvWeb.CodeHighlight), so `not` sits in a span and
    # the full line is no longer one contiguous string. The unlabelled fence and
    # the inline span are untouched by both features.
    test "leaves every other code block alone" do
      for {fence, text} <- [
            {"```elixir\n- not a diff\n```", "a diff"},
            {"```\n- not a diff\n```", "- not a diff"},
            {"`- inline`", "- inline"}
          ] do
        html = render(fence)

        refute html =~ "diff-line"
        assert html =~ text
      end
    end
  end

  describe "safety" do
    test "keeps typed HTML inside a diff escaped" do
      html = render(diff_post("+ <script>alert(1)</script>"))

      refute html =~ "<script"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "a fence language cannot smuggle an attribute into the block we emit" do
      # The class we write is a literal of ours, never the author's fence text
      # (which is why the block is re-emitted rather than patched in place).
      assert render(diff_post("+ added")) =~ ~s(<pre class="diff-block"><code class="diff">)

      html = render("```diff onclick=alert(1)\n+ added\n```")

      refute html =~ ~r/<[^>]*onclick/
    end

    test "a line that merely looks like a fence end cannot break out of the block" do
      html = render(diff_post("+ </code></pre><script>alert(1)</script>"))

      refute html =~ "<script"
      # everything after the fake closer is still inside the block
      assert html =~ "&lt;/code&gt;&lt;/pre&gt;"
    end
  end

  describe "stylesheet" do
    setup do
      css = File.read!(@components_css)
      [light, dark] = String.split(css, ~r/@media\s*\(prefers-color-scheme:\s*dark\)/, parts: 2)
      %{light: light, dark: dark}
    end

    test "colours added and removed rows in both schemes", %{light: light, dark: dark} do
      for scheme <- [light, dark], class <- ~w(add del) do
        assert scheme =~ ~r/\.diff-line--#{class}\s*\{[^}]*background/,
               "`.diff-line--#{class}` needs a background in both colour schemes"
      end
    end

    test "the marker keeps its own colour, so the row is not told by tint alone", %{
      light: light,
      dark: dark
    } do
      for scheme <- [light, dark] do
        assert scheme =~ ~r/\.diff-line--add \.diff-line__marker\s*\{[^}]*color/
        assert scheme =~ ~r/\.diff-line--del \.diff-line__marker\s*\{[^}]*color/
      end
    end
  end
end
