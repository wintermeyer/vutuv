defmodule VutuvWeb.MarkdownCodeFenceTest do
  use ExUnit.Case, async: true

  # Issues #1137 and #1138: a code fence may name the file a snippet comes from
  # and, for a diff, the language the diff is written in. Both are written
  # either after a colon or as an attribute, and both syntaxes have to come out
  # the same way — which is the point of these tests, because the two forms
  # take completely different routes through the pipeline (the colon form
  # survives Earmark untouched; the attribute form is folded into it before
  # Earmark ever sees the line, since a fence with a space in its info string
  # is not parsed as a fence at all).
  #
  # The last group pins the round trip through the composer: Milkdown keeps a
  # code block's first word and nothing else, so the editor has to do the same
  # folding on the way in or a title is destroyed the moment a post is edited.

  alias VutuvWeb.CodeHighlight.Fences
  alias VutuvWeb.Markdown

  @editor_js Path.expand("../../assets/js/markdown_editor.js", __DIR__)
  @components_css Path.expand("../../assets/css/components.css", __DIR__)

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  describe "a fence that names its file (issue #1137)" do
    test "the short form puts the name in a real element above the code" do
      html = render("```php:config/app.php\n$a = 1;\n```")

      assert html =~ ~s(<div class="codeblock codeblock--titled")
      assert html =~ ~s(data-title="config/app.php")
      assert html =~ ~s(<span class="codeblock__file">config/app.php</span>)
    end

    test "the attribute form renders exactly the same block" do
      assert render(~s(```php title="config/app.php"\n$a = 1;\n```)) ==
               render("```php:config/app.php\n$a = 1;\n```")
    end

    test "a single-quoted and an unquoted title work too" do
      for info <- [~s(title='app.php'), "title=app.php"] do
        assert render("```php #{info}\n$a = 1;\n```") =~
                 ~s(<span class="codeblock__file">app.php</span>)
      end
    end

    test "the language keeps its own name in the bar, and loses the corner label" do
      html = render("```php:app.php\n$a = 1;\n```")

      assert html =~ ~s(<span class="codeblock__lang">PHP</span>)
      assert html =~ ~s(data-language="PHP")
    end

    test "the code is still highlighted and still named as PHP" do
      html = render("```php:app.php\n// note\n```")

      assert html =~ ~s(<code class="language-php">)
      assert html =~ ~s(<span class="hl-com">// note</span>)
    end

    test "a title may hold a space when it is written as an attribute" do
      assert render(~s(```elixir title="two words.ex"\nx = 1\n```)) =~
               ~s(<span class="codeblock__file">two words.ex</span>)
    end

    test "a fence with no title keeps the plain wrapper and the corner label" do
      html = render("```php\n$a = 1;\n```")

      assert html =~ ~s(<div class="codeblock" data-language="PHP">)
      refute html =~ "codeblock__title"
      refute html =~ "data-title"
    end

    test "a title cannot break out of the attribute, the class or the element" do
      html = render(~s[```php title="a\" onmouseover=\"steal"\nx\n```])

      refute html =~ "onmouseover"
      refute html =~ "steal"

      html = render("```php:<script>alert(1)</script>\nx\n```")

      refute html =~ "<script"
    end

    test "an unknown language may still name its file" do
      html = render("```fortran:hello.f90\nPROGRAM x\n```")

      assert html =~ ~s(data-title="hello.f90")
      assert html =~ ~s(<span class="codeblock__lang">fortran</span>)
    end
  end

  describe "a diff that names its language (issue #1138)" do
    @diff """
    ```diff:php
    $a = 1;
    - $b = 2;
    + $b = 42;
    ```
    """

    test "the rows are still a diff" do
      html = render(@diff)

      assert html =~ ~s(<pre class="diff-block">)
      assert html =~ ~s(diff-line diff-line--add)
      assert html =~ ~s(diff-line diff-line--del)
    end

    test "and the code inside them is coloured as that language" do
      html = render(@diff)

      assert html =~ ~s(<span class="hl-lit">$b</span>)
      assert html =~ ~s(<span class="hl-num">42</span>)
    end

    test "the marker stays out of the highlighted code" do
      html = render(@diff)

      assert html =~ ~s(<span class="diff-line__marker">+</span>)
      refute html =~ ~s(hl-num">+)
    end

    test "the attribute form renders exactly the same block" do
      assert render(~s(```diff lang="php"\n$a = 1;\n- $b = 2;\n+ $b = 42;\n```)) == render(@diff)
    end

    test "the block is labelled Diff and carries both languages on the code element" do
      html = render(@diff)

      assert html =~ ~s(data-language="Diff")
      assert html =~ ~s(<code class="diff language-php">)
    end

    test "a plain diff fence is untouched by any of this" do
      html = render("```diff\n- a\n+ b\n```")

      assert html =~ ~s(<code class="diff">)
      refute html =~ "hl-"
    end

    test "hunk and file headers are not lexed as code" do
      html = render("```diff:elixir\n@@ -1,2 +1,2 @@\ndiff --git a/x b/x\n- def a do\n```")

      assert html =~ ~s(diff-line--hunk"><span class="diff-line__marker"></span>@@ -1,2 +1,2 @@)
      assert html =~ ~s(diff-line--meta"><span class="diff-line__marker"></span>diff --git)
      assert html =~ ~s(<span class="hl-key">def</span>)
    end

    test "a diff may name its file as well as its language" do
      html = render(~s(```diff lang="php" title="app.php"\n- $a = 1;\n```))

      assert html =~ ~s(data-title="app.php")
      assert html =~ ~s(<code class="diff language-php">)
    end
  end

  describe "info strings the fence parser has to survive" do
    test "a fence whose info string has a space is a fence again" do
      # Earmark parses none of these as a fence on its own — the whole block
      # collapses into one run of inline code — so any of them used to render
      # as garbage, not just the two new syntaxes.
      html = render("```js react\nlet x = 1\n```")

      assert html =~ ~s(<code class="language-javascript">)
      refute html =~ ~s(<code class="inline">)
    end

    test "an unknown attribute is dropped rather than breaking the block" do
      assert render("```python showLineNumbers\nx = 1\n```") =~
               ~s(<code class="language-python">)
    end

    test "a fence with no info string at all is left alone" do
      html = render("```\nplain\n```")

      assert html =~ "<pre><code>plain</code></pre>"
      refute html =~ "codeblock"
    end

    test "the fence markers inside a block are not treated as fences" do
      html = render("````markdown\n```php title=\"a.php\"\nx\n```\n````")

      assert html =~ ~s[```php title="a.php"]
    end

    test "a tilde fence works the same way" do
      assert render("~~~php:app.php\n$a = 1;\n~~~") =~ ~s(data-title="app.php")
    end
  end

  describe "Fences.normalize/1" do
    test "leaves an ordinary fence byte for byte" do
      for source <- ["```\nx\n```", "```php\nx\n```", "text with no fence at all"] do
        assert Fences.normalize(source) == source
      end
    end

    test "is a fixed point: normalizing twice changes nothing" do
      for source <- [
            ~s(```php title="a b.php"\nx\n```),
            "```diff:php\nx\n```",
            "```php:app.php\nx\n```"
          ] do
        once = Fences.normalize(source)

        assert Fences.normalize(once) == once
      end
    end

    test "never leaves a space in the info string, whatever it was handed" do
      [first | _] =
        ~s(```php title="a b.php" lang=x showLineNumbers {2,4}\nx\n```)
        |> Fences.normalize()
        |> String.split("\n")

      refute first =~ " "
    end
  end

  describe "the composer keeps what the member typed (Milkdown round trip)" do
    # There is no JS test runner in this project, so this is a static source
    # check in the spirit of markdown_editor_resize_test.exs. Milkdown's
    # code_block node stores an info string's FIRST WORD as its language and
    # serializes only that back, so an attribute-form title is destroyed by a
    # round trip unless the editor folds it into the colon form on the way in.
    test "the editor folds an attribute-form fence into the colon form on load" do
      js = File.read!(@editor_js)

      assert js =~ "rewriteFenceInfo("
      assert js =~ ~r/escapeFootnotes\(md\)\s*\{\s*return this\.rewriteFenceInfo\(/s
    end

    test "and both halves of the file-name bar are styled, light and dark" do
      css = File.read!(@components_css)

      assert css =~ ~r/^\.codeblock__title \{/m
      assert css =~ ~r/@media \(prefers-color-scheme: dark\)[\s\S]*\.codeblock__title \{/
    end
  end

  describe "the composer previews what the renderer will do (issues #1108, #1137, #1138)" do
    # The published post renders a diff fence as tinted rows and a titled fence
    # with its file-name bar — but the composer used to show the same block as a
    # plain grey box, which read as "the fence did not work" and is why all
    # three issues were reopened. The preview is a ProseMirror decoration
    # plugin in the editor hook; like the round-trip tests above, these are
    # static source checks (no JS test runner) plus the drift guards that keep
    # the JS classification aligned with VutuvWeb.CodeHighlight.Diff.
    test "the editor carries a code fence preview plugin" do
      js = File.read!(@editor_js)

      assert js =~ "codeFencePreview"
      assert js =~ ~r/\.use\(codeFencePreview\(/
    end

    test "the JS row classification mirrors Diff.classify/1, meta before add/del" do
      js = File.read!(@editor_js)

      # The server's rule: hunk first, then the file headers (so `+++` is never
      # an added line), then the single-character markers.
      assert js =~ ~r/@@[\s\S]*?mde-diff--hunk/

      assert js =~
               ~r/mde-diff--hunk[\s\S]*?mde-diff--meta[\s\S]*?mde-diff--add[\s\S]*?mde-diff--del/

      # The meta prefixes are the server's list (VutuvWeb.CodeHighlight.Diff).
      for prefix <- ["+++", "diff ", "index ", "rename from", "\\\\ No newline"] do
        assert js =~ prefix, "missing diff meta prefix in the editor: #{inspect(prefix)}"
      end
    end

    test "the diff words the editor recognises are the server's" do
      js = File.read!(@editor_js)

      # `diff` plus the aliases Languages maps onto it.
      assert js =~ ~r/diff\|patch\|udiff/
    end

    test "the preview styles exist, light and dark" do
      css = File.read!(@components_css)

      for class <- ~w(mde-codeblock mde-codeblock--titled mde-diff--add mde-diff--del
                      mde-diff--hunk mde-diff--meta) do
        assert css =~ class, "missing composer preview class: .#{class}"

        assert css =~ ~r/@media \(prefers-color-scheme: dark\)[\s\S]*#{Regex.escape(class)}/,
               "missing dark counterpart for .#{class}"
      end
    end
  end
end
