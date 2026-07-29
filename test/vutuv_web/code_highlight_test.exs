defmodule VutuvWeb.CodeHighlightTest do
  use ExUnit.Case, async: true

  alias VutuvWeb.CodeHighlight

  describe "render/1 — the language label (issue #1106)" do
    test "wraps a labelled fence and names the language" do
      html = CodeHighlight.render(~s(<pre><code class="elixir">x = 1</code></pre>))

      assert html =~ ~s(<div class="codeblock" data-language="Elixir">)
      assert html =~ ~s(<code class="language-elixir">)
    end

    test "resolves an alias to the canonical label" do
      assert CodeHighlight.render(~s(<pre><code class="py">x = 1</code></pre>)) =~
               ~s(data-language="Python")

      assert CodeHighlight.render(~s(<pre><code class="js">let x</code></pre>)) =~
               ~s(data-language="JavaScript")
    end

    test "ignores the trailing part of a decorated info string" do
      assert CodeHighlight.render(~s(<pre><code class="js:app.js">let x</code></pre>)) =~
               ~s(data-language="JavaScript")
    end

    test "an unlabelled fence is left exactly as it was" do
      html = ~s(<pre><code>plain text</code></pre>)

      assert CodeHighlight.render(html) == html
    end

    test "the conventional no-language markers show no label" do
      for marker <- ~w(text plain none txt) do
        html = CodeHighlight.render(~s(<pre><code class="#{marker}">x</code></pre>))

        refute html =~ "data-language"
        refute html =~ "codeblock"
      end
    end

    test "an unknown language is still labelled, just not highlighted" do
      html = CodeHighlight.render(~s(<pre><code class="fortran">PROGRAM x</code></pre>))

      assert html =~ ~s(data-language="fortran")
      assert html =~ ~s(<code class="language-fortran">PROGRAM x</code>)
    end

    test "a hostile info string can neither break out of the attribute nor the class" do
      html =
        CodeHighlight.render(
          ~s[<pre><code class="a&quot; onmouseover=&quot;steal">x</code></pre>]
        )

      refute html =~ "onmouseover"
      refute html =~ "steal"
    end

    test "leaves everything around the code block untouched" do
      html = CodeHighlight.render(~s(<p>before</p><pre><code>x</code></pre><p>after</p>))

      assert html =~ "<p>before</p>"
      assert html =~ "<p>after</p>"
    end
  end

  describe "render/1 — syntax highlighting (issue #1107)" do
    test "marks keywords, strings, numbers and comments" do
      code = ~s[defmodule Foo do\n  # a note\n  @x "hi"\n  def n, do: 42\nend]
      html = CodeHighlight.render(~s(<pre><code class="elixir">#{code}</code></pre>))

      assert html =~ ~s(<span class="hl-key">defmodule</span>)
      assert html =~ ~s(<span class="hl-com"># a note</span>)
      assert html =~ ~s(<span class="hl-lit">@x</span>)
      assert html =~ ~s[<span class="hl-str">"hi"</span>]
      assert html =~ ~s(<span class="hl-num">42</span>)
    end

    test "highlights a language whose comments are C style" do
      code = ~s[// note\nconst x = 1;]
      html = CodeHighlight.render(~s(<pre><code class="javascript">#{code}</code></pre>))

      assert html =~ ~s(<span class="hl-com">// note</span>)
      assert html =~ ~s(<span class="hl-key">const</span>)
    end

    test "highlights a block comment" do
      html = CodeHighlight.render(~s(<pre><code class="c">/* hi */ int x;</code></pre>))

      assert html =~ ~s(<span class="hl-com">/* hi */</span>)
    end

    test "does not run a string past the end of its line" do
      code = ~s[x = "unterminated\ny = 1]
      html = CodeHighlight.render(~s(<pre><code class="python">#{code}</code></pre>))

      assert html =~ ~s(<span class="hl-num">1</span>)
    end

    test "handles a triple-quoted Python string" do
      code = ~s[s = """one\ntwo"""\nn = 3]
      html = CodeHighlight.render(~s(<pre><code class="python">#{code}</code></pre>))

      assert html =~ ~s(<span class="hl-num">3</span>)
    end

    test "marks a shell variable and a Ruby symbol as literals" do
      assert CodeHighlight.render(~s(<pre><code class="bash">echo $HOME</code></pre>)) =~
               ~s(<span class="hl-lit">$HOME</span>)

      assert CodeHighlight.render(~s(<pre><code class="ruby">x = :sym</code></pre>)) =~
               ~s(<span class="hl-lit">:sym</span>)
    end

    test "keyword lookup is case insensitive where the language is" do
      html = CodeHighlight.render(~s(<pre><code class="sql">SELECT 1 from t</code></pre>))

      assert html =~ ~s(<span class="hl-key">SELECT</span>)
      assert html =~ ~s(<span class="hl-key">from</span>)
    end

    test "markup highlights tag and attribute names" do
      html =
        CodeHighlight.render(
          ~s(<pre><code class="html">&lt;a href="/x"&gt;hi&lt;/a&gt;</code></pre>)
        )

      assert html =~ ~s(<span class="hl-tag">a</span>)
      assert html =~ ~s(<span class="hl-att">href</span>)
      refute html =~ ~s(<a href="/x">)
    end

    # A diff fence is labelled here and rendered as real added / removed rows by
    # `VutuvWeb.Markdown.highlight_diff_blocks/1` (issue #1108), which runs
    # after us and needs to find its `<pre><code class="language-diff">` intact.
    test "a diff fence is labelled but its body is left for the diff renderer" do
      code = ~s[@@ -1 +1 @@\n-old\n+new\n ctx]
      html = CodeHighlight.render(~s(<pre><code class="diff">#{code}</code></pre>))

      assert html =~ ~s(data-language="Diff")
      assert html =~ ~s(<pre><code class="language-diff">#{code}</code></pre>)
      refute html =~ "hl-"
    end

    test "an oversized block keeps its label but is not highlighted" do
      code = String.duplicate("def x\n", 20_000)
      html = CodeHighlight.render(~s(<pre><code class="ruby">#{code}</code></pre>))

      assert html =~ ~s(data-language="Ruby")
      refute html =~ "hl-key"
    end
  end

  describe "render/1 — escaping" do
    test "never unescapes markup that lives inside the code" do
      html =
        CodeHighlight.render(
          ~s[<pre><code class="javascript">&lt;script&gt;boom&lt;/script&gt;</code></pre>]
        )

      refute html =~ "<script>"
      refute html =~ "</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "round-trips ampersands, angle brackets and quotes unchanged" do
      body = ~s(a &amp; b &lt; c &gt; d "q" 'r')
      html = CodeHighlight.render(~s(<pre><code class="elixir">#{body}</code></pre>))

      assert text_of(html) == body
    end

    test "highlighting a string does not swallow the quotes" do
      html = CodeHighlight.render(~s(<pre><code class="json">{"a": 1}</code></pre>))

      assert text_of(html) == ~s({"a": 1})
    end

    test "leaves a block alone when its escaping is not the form we can rebuild" do
      html = ~s(<pre><code class="elixir">a &nbsp; b</code></pre>)

      assert CodeHighlight.render(html) =~ ~s(a &nbsp; b)
      refute CodeHighlight.render(html) =~ "hl-"
    end

    test "highlights a block whose quotes arrive as &quot; and writes them back that way" do
      # `Earmark.as_ast` + `Transform` — the developer docs and the legal pages
      # — escapes a double quote, `as_html!` (posts) does not. Reading only the
      # second spelling used to fail the round-trip check for every doc block
      # containing a quote, which is most of them, so a `curl -H "…"` line lost
      # its colours while the same snippet in a post kept them.
      html =
        CodeHighlight.render(
          ~s(<pre><code class="bash"># fetch\ncurl -H &quot;Accept: text/plain&quot; /x</code></pre>)
        )

      assert html =~ ~s(<span class="hl-com"># fetch</span>)
      assert html =~ ~s(<span class="hl-str">&quot;Accept: text/plain&quot;</span>)
      refute html =~ ~s(&amp;quot;)
    end

    test "a block mixing both quote spellings is left alone rather than rewritten" do
      html = ~s(<pre><code class="elixir">a &quot;x&quot; b "y"</code></pre>)

      assert CodeHighlight.render(html) =~ ~s(a &quot;x&quot; b "y")
      refute CodeHighlight.render(html) =~ "hl-"
    end
  end

  # The code text with every tag removed, so a test can assert that highlighting
  # changed the markup and nothing else.
  defp text_of(html) do
    html
    |> String.replace(~r{^.*<code[^>]*>}s, "")
    |> String.replace(~r{</code>.*$}s, "")
    |> String.replace(~r{</?span[^>]*>}, "")
  end
end
