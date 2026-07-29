defmodule VutuvWeb.Markdown.Footnotes do
  # A body may not grow an unbounded note list. Bodies are capped at 20,000
  # characters, which leaves room for hundreds of references; this keeps the
  # apparatus at a size a reader can still use and caps the per-body work.
  @max_footnotes 50

  @moduledoc """
  Markdown footnotes for user-written bodies (issue #1147).

      Ein Satz mit Anmerkung[^1].

      [^1]: Die Anmerkung dazu.

  renders the reference as a superscript `[1]` linked to a numbered note list
  at the end of the body, and each note links back to where it was cited.

  **Why this is not Earmark's `footnotes: true`.** Earmark can do footnotes, but
  it wires reference and note together with `id="fn:1"` / `class="footnote"` —
  and `HtmlSanitizeEx.markdown_html/1`, which every user-written body must pass,
  allows `id` on **no** tag and `class` only on `<code>`. Earmark's links would
  survive the scrubber with every one of their targets stripped. Its ids are
  also global (`fn:1`), so twenty feed cards would all claim the same anchor. So
  this module does what `VutuvWeb.Markdown` already does for inline images and
  for `diff` blocks: it swaps the footnote syntax for unguessable plain-text
  markers *before* rendering and builds the real markup from known-safe parts
  *after* sanitizing, with a per-render nonce namespacing every id.

  **The rules, all deliberately strict and predictable:**

    * A definition is a single line starting at column 0: `[^label]: text`.
      Prose that runs long belongs in the post, not in a note.
    * Notes are numbered by **first reference**, not by definition order, and one
      label referenced twice shares one note.
    * Half-typed syntax stays exactly as typed: a reference with no definition
      and a definition nobody references both render as literal text. Nothing a
      member wrote ever disappears silently.
    * Code is sample text: a reference or a definition inside a fenced block or
      an inline code span is left alone.
    * At most #{@max_footnotes} notes per body; references past that stay literal.

  The composer's serializer (remark, via Milkdown) escapes `[` in prose, so a
  body written in the WYSIWYG can arrive as `\\[^1]`. The hook canonicalizes that
  away at write time (`assets/js/markdown_editor.js`); the optional backslash in
  the patterns below is the rendering-side guard for anything stored before
  that, the same deal `Vutuv.Mentions` makes for an escaped `@handle`.
  """
  use Gettext, backend: VutuvWeb.Gettext

  alias VutuvWeb.Markdown

  # A label is one whitespace-free run inside `[^…]`. Length-capped so a
  # pathological body cannot drive the scan, and `]`-free so a match can never
  # run past its own brackets.
  @label "[^\\]\\s]{1,64}"

  @reference Regex.compile!("\\\\?\\[\\^(#{@label})\\]")

  # A definition owns its whole line, from column 0, and needs a non-blank body
  # (`[^1]:` with nothing after it is not a definition, so it stays as typed).
  @definition Regex.compile!("^\\\\?\\[\\^(#{@label})\\]:[ \\t]*(\\S[^\\n]*)", [:multiline])

  # Cheap substring guard: a body with no `[^` anywhere skips every pass below.
  # The escaped form `\[^1]` contains it too, so this misses nothing.
  @sigil "[^"

  # The back-link glyph, U+21A9 followed by U+FE0E — the **text** variation
  # selector, and it is not optional. Bare, U+21A9 has emoji presentation by
  # default on macOS and iOS, so the quiet little arrow came out as a filled grey
  # keycap that read as a button sitting in the middle of the note list (caught in
  # the browser, not by any test). U+FE0E pins it to the text glyph, which then
  # inherits the link colour and the surrounding type size like any other
  # character.
  @backref_glyph "&#8617;&#xFE0E;"

  @doc "How many notes one body may carry."
  def max_footnotes, do: @max_footnotes

  @doc """
  Rewrites footnote syntax into markers, ready for the Markdown pipeline.

  Returns `{prepared_source, state}` — hand `state` to `inject/2` once the
  pipeline has rendered and sanitized the result. `state` is `nil` when the body
  carries no usable footnote, in which case the source comes back unchanged and
  `inject/2` is a no-op.
  """
  def prepare(text) when is_binary(text) do
    if String.contains?(text, @sigil), do: prepare_present(text), else: {text, nil}
  end

  def prepare(text), do: {text, nil}

  defp prepare_present(text) do
    chunks = Markdown.split_code_regions(text)
    definitions = collect_definitions(chunks)
    numbers = number_references(chunks, definitions)

    if map_size(numbers) == 0 do
      {text, nil}
    else
      nonce = Base.encode16(:crypto.strong_rand_bytes(6))
      {rewrite(chunks, definitions, numbers, nonce), %{nonce: nonce}}
    end
  end

  @doc """
  Builds the real footnote markup out of the markers `prepare/1` left behind.

  Runs on **sanitized** HTML, so everything it emits is either a literal of ours
  (the classes, the ids, the anchors) or output the scrubber already cleared
  (the note bodies, re-emitted verbatim). A marker that somehow survived without
  its note — a body ending in an unclosed code fence swallows the appended
  definitions — degrades to a plain `[n]` rather than leaking the marker text.
  """
  def inject(html, nil), do: html

  def inject(html, %{nonce: nonce}) do
    {stripped, notes} = take_notes(html, nonce)

    stripped
    |> link_references(nonce, notes)
    |> Kernel.<>(note_list(nonce, notes))
    |> scrub_markers(nonce)
  end

  @doc """
  Splits a body into `{prose, definitions}` at the source level.

  For `VutuvWeb.Markdown.render_preview/3`: the definitions sit at the end of a
  body, so cutting a long post down to preview length would cut them off and
  strand every reference in the visible text. The preview cuts the prose alone,
  and `reattach/2` puts back the notes the surviving text still cites.
  """
  def split_definitions(text) when is_binary(text) do
    if String.contains?(text, @sigil), do: split_present(text), else: {text, []}
  end

  def split_definitions(text), do: {text, []}

  defp split_present(text) do
    chunks = Markdown.split_code_regions(text)
    definitions = collect_definitions(chunks)

    if map_size(definitions) == 0 do
      {text, []}
    else
      prose = chunks |> strip_definitions(Map.keys(definitions)) |> join()
      {prose, Map.to_list(definitions)}
    end
  end

  @doc "Appends the definitions `prose` still cites, undoing `split_definitions/1`."
  def reattach(prose, []), do: prose

  def reattach(prose, definitions) do
    cited = prose |> Markdown.split_code_regions() |> referenced_labels()

    case Enum.filter(definitions, fn {label, _body} -> label in cited end) do
      [] ->
        prose

      kept ->
        String.trim_trailing(prose) <> "\n\n" <> Enum.map_join(kept, "\n", &definition_line/1)
    end
  end

  defp definition_line({label, body}), do: "[^#{label}]: #{body}"

  ## Source rewriting

  # `%{label => body}`, first definition of a label wins.
  defp collect_definitions(chunks) do
    chunks
    |> scan_text(@definition)
    |> Enum.reduce(%{}, fn [label, body], acc ->
      Map.put_new(acc, label, String.trim_trailing(body))
    end)
  end

  # `%{label => number}` for the defined labels, in order of first reference and
  # capped. The scan runs on a copy with **every** candidate definition line
  # removed: a definition line carries its own label in brackets, so counting it
  # would number the notes by definition order instead of by citation order.
  defp number_references(chunks, definitions) do
    chunks
    |> strip_definitions(Map.keys(definitions))
    |> referenced_labels()
    |> Enum.filter(&Map.has_key?(definitions, &1))
    |> Enum.take(@max_footnotes)
    |> Enum.with_index(1)
    |> Map.new()
  end

  # The labels cited in prose, in order, without repeats.
  defp referenced_labels(chunks) do
    chunks
    |> scan_text(@reference)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end

  defp scan_text(chunks, pattern) do
    Enum.flat_map(chunks, fn
      {:text, chunk} -> Regex.scan(pattern, chunk, capture: :all_but_first)
      {:code, _chunk} -> []
    end)
  end

  defp strip_definitions(chunks, labels) do
    map_text(chunks, &strip_definition_lines(&1, labels))
  end

  defp strip_definition_lines(chunk, labels) do
    Regex.replace(@definition, chunk, fn whole, label, _body ->
      if label in labels, do: "", else: whole
    end)
  end

  # Definition lines out of the prose, references to markers, and the numbered
  # definitions appended as marker-led paragraphs so the pipeline renders each
  # note body exactly like any other prose (links, emphasis, mentions and all).
  defp rewrite(chunks, definitions, numbers, nonce) do
    body =
      chunks
      |> strip_definitions(Map.keys(numbers))
      |> map_text(&mark_references(&1, numbers, nonce))
      |> join()
      |> String.trim_trailing()

    notes =
      numbers
      |> Enum.sort_by(fn {_label, number} -> number end)
      |> Enum.map_join("\n\n", fn {label, number} ->
        "#{note_marker(nonce, number)} #{Map.fetch!(definitions, label)}"
      end)

    body <> "\n\n" <> notes <> "\n"
  end

  defp mark_references(chunk, numbers, nonce) do
    Regex.replace(@reference, chunk, fn whole, label ->
      case Map.fetch(numbers, label) do
        {:ok, number} -> reference_marker(nonce, number)
        :error -> whole
      end
    end)
  end

  defp map_text(chunks, fun) do
    Enum.map(chunks, fn
      {:text, chunk} -> {:text, fun.(chunk)}
      {:code, chunk} -> {:code, chunk}
    end)
  end

  defp join(chunks), do: Enum.map_join(chunks, "", fn {_kind, chunk} -> chunk end)

  ## Markers

  # Plain alphanumeric runs: Markdown leaves them alone, the scrubber has no
  # reason to touch them, and the nonce makes one unguessable, so an author
  # cannot type a marker that collides with a real one.
  defp reference_marker(nonce, number), do: "VUTUVFNR#{nonce}N#{number}END"
  defp note_marker(nonce, number), do: "VUTUVFND#{nonce}N#{number}END"

  ## HTML assembly

  # Lifts the rendered note paragraphs out of the body. Each is its own `<p>` led
  # by the marker (the marker starts its source line, so the block can only ever
  # be a paragraph), which is what makes them findable after the scrubber has
  # dropped every attribute we could otherwise have marked them with.
  defp take_notes(html, nonce) do
    pattern = Regex.compile!("<p>\\s*VUTUVFND#{nonce}N(\\d+)END\\s*(.*?)</p>", "s")
    found = Regex.scan(pattern, html)

    {stripped, notes} =
      Enum.reduce(found, {html, []}, fn [whole, number, body], {html, notes} ->
        {String.replace(html, whole, ""), [{String.to_integer(number), body} | notes]}
      end)

    {stripped, Enum.sort(notes)}
  end

  defp link_references(html, nonce, notes) do
    Enum.reduce(notes, html, fn {number, _body}, html ->
      String.replace(html, reference_marker(nonce, number), reference_html(nonce, number))
    end)
  end

  # The brackets are not decoration: `<sup>` is outside what Mastodon and most
  # feed readers keep, and without them the number would fuse into the word it
  # follows ("Satz1"). Brackets survive tag-stripping, so the citation still
  # reads as one everywhere this HTML travels.
  defp reference_html(nonce, number) do
    ~s(<sup class="footnote-ref" id="#{ref_id(nonce, number)}">) <>
      ~s(<a href="##{note_id(nonce, number)}">[#{number}]</a></sup>)
  end

  defp note_list(_nonce, []), do: ""

  defp note_list(nonce, notes) do
    label = gettext("Back to the text")

    items =
      Enum.map_join(notes, "", fn {number, body} ->
        ~s(<li id="#{note_id(nonce, number)}">#{body} ) <>
          ~s(<a class="footnote-backref" href="##{ref_id(nonce, number)}" ) <>
          ~s(aria-label="#{label}" title="#{label}">#{@backref_glyph}</a></li>)
      end)

    ~s(<div class="footnotes"><ol>#{items}</ol></div>)
  end

  defp ref_id(nonce, number), do: "fnref-#{nonce}-#{number}"
  defp note_id(nonce, number), do: "fn-#{nonce}-#{number}"

  # A body that ends inside an unclosed code fence swallows the appended
  # definitions, so their paragraphs never materialize and the references above
  # are left pointing at nothing. Rather than leak the marker text, show the
  # citation number plainly and drop the orphaned note marker.
  defp scrub_markers(html, nonce) do
    html
    |> String.replace(Regex.compile!("VUTUVFNR#{nonce}N(\\d+)END"), "[\\1]")
    |> String.replace(Regex.compile!("VUTUVFND#{nonce}N\\d+END"), "")
  end
end
