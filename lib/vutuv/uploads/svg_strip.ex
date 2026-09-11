defmodule Vutuv.Uploads.SvgStrip do
  @moduledoc """
  `Vutuv.Uploads.MetadataStrip` for the one format that is not a container: the
  vector logo a Media Kit hands out (issue #2145).

  A JPEG, a PNG and a WebP keep their metadata in segments beside the picture,
  so the stripper next door can drop those segments and copy the rest byte for
  byte. An SVG is a **document**: the trail an editor leaves sits in the same
  tree as the drawing, so removing it is a rewrite — and a rewrite that changes
  how a logo renders is worse than the leak it fixes, because a brand mark is
  the one file where a pixel of drift is a defect.

  Two rules keep the rewrite honest.

  **Only what the SVG specification says is not rendered comes out**, and it
  comes out whole:

    * XML comments — where "Generator: Adobe Illustrator …" lives, and where a
      designer's note to themselves ends up
    * the `<metadata>` element and its subtree (SVG 1.1 §5.10: it has no
      rendering). Inkscape writes the author, the licence and the date there
    * every element and every attribute in a namespace that is **not** SVG,
      XLink or XML, together with the `xmlns:` declaration that bound it. That
      is a whitelist, so `sodipodi:namedview` (the editing window),
      `inkscape:label` and `sodipodi:docname` (the designer's own file name,
      often a path through their home directory) leave without this module
      having heard of any of them — and so does the next editor's private
      namespace

  **Everything kept is copied verbatim.** Names, quoting, entity escapes,
  whitespace and attribute order are the bytes that arrived; nothing is
  re-serialised, so a parser's idea of equivalent markup never gets to differ
  from the author's.

  The one exception is the **`data:` URI**, and it is the leak the issue was
  filed for: a logo can carry a base64 photograph, and that photograph carries
  the GPS fix and the camera serial the Media Kit promises never to hand out.
  Those bytes go through `MetadataStrip` and back into the same attribute, which
  is the same "pixels untouched" promise one level down.

  **What deliberately stays.** `<title>` and `<desc>` are the accessible name
  and description of the drawing — a screen reader reads them, a browser shows
  the title as a tooltip — so they are part of how the file behaves rather than
  a trail: text the member wrote *into* the logo. `id`, `class` and `style` stay
  because `url(#…)` resolves through them. So do the XML declaration and any
  processing instruction — but a `data:` URI inside one is cleaned like every
  other, because "not rendered" is not "not read": a `<?xpacket?>` or an
  `<?xml-stylesheet?>` is a place an editor can park a photograph, and a
  photograph is exactly what carries the serial.

  **What it refuses rather than removes.** An `on…` attribute is a **script
  handler** (issue #2181), and a script is the one thing here that is not a
  trail: removing it would change what the member's file does, and leaving it
  would hand a journalist a document that runs code the moment they open it —
  our own origin never renders one (the download leaves as an attachment under
  `nosniff`), but the person who saves it opens a standalone `.svg`, and that is
  a document with a script in it. So the file is refused, which is also the
  answer the member can act on: their export carries interactivity a logo has no
  use for. The check reads attribute **names off the parser**, never a pattern
  over the whole document, so the same letters inside a `<title>` or a `<desc>`
  are prose; only an attribute in **no** namespace counts, because a prefixed
  one binds no event anywhere and leaves with its namespace in any case.

  **It fails closed**, like the stripper beside it: markup this module cannot
  take apart with certainty — a DOCTYPE, a tag it cannot parse, a `data:` URI it
  cannot clean — yields `{:error, reason}`, and the caller then offers no
  download at all rather than the untouched file.

  The `reason` is one word, and three of them are named so a surface can say
  what happened instead of "that file could not be processed" (issue #2182):
  `:svg_event_handler` above, `:svg_embedded_file` for a payload no container
  stripper can take apart (a webfont, an SVG inside the SVG) and
  `:svg_unreadable_data` for a `data:` run this module cannot decode at all —
  which is a percent-encoded payload **and** a description that merely reads
  like one, since nothing can tell those apart from outside the author's head.
  Everything structural is `:unclean`.

  And because an argument about what a renderer ignores is still an argument,
  `clean/1` **checks it**: the file that comes back is rasterised beside the file
  that went in (`Vutuv.Uploads.Spec.open_rotated_binary/1`, the same librsvg the
  preview is drawn with) and the two pixel buffers must be identical, or the
  answer is a refusal. A namespace this module got wrong therefore costs a
  download, never a changed logo.
  """

  alias Vix.Vips.Image, as: VipsImage
  alias Vutuv.Uploads.MetadataStrip
  alias Vutuv.Uploads.Spec

  @svg_ns "http://www.w3.org/2000/svg"
  @xlink_ns "http://www.w3.org/1999/xlink"
  @xml_ns "http://www.w3.org/XML/1998/namespace"
  @keep_ns [@svg_ns, @xlink_ns, @xml_ns]

  # `xml` is bound by the XML specification itself and never declared. `xlink`
  # is declared by every editor that uses it, and librsvg refuses a document
  # that uses the prefix without declaring it (measured, see the test) — so
  # binding it here is belt and braces: dropping an `xlink:href` would take an
  # embedded picture off the canvas, and that is the one mistake worth two
  # lines of defence.
  @root_scope %{"xml" => @xml_ns, "xlink" => @xlink_ns}

  @whitespace ~c" \t\r\n"
  @name_stop ~c" \t\r\n/>=<"

  # A `data:` URI wherever it sits: an `xlink:href`, a `style` attribute, a
  # `url(…)` inside a `<style>` block. The payload class stops at the quote, the
  # paren or the `<` that ends it and takes the newlines an editor wraps long
  # base64 with. The lookbehind is what keeps `metadata:` from matching.
  @data_uri ~r/(?<![A-Za-z0-9])data:([^,"'()\s<>]*),([A-Za-z0-9+\/=\s]*)/

  @doc "Whether this module is what cleans a file with this extension."
  def supported?(ext) when is_binary(ext), do: String.downcase(ext) == ".svg"
  def supported?(_ext), do: false

  @doc """
  The markup with every non-rendering trail removed, as `{:ok, binary}`, or
  `{:error, reason}` for anything this module cannot clean *and* prove
  unchanged — see the moduledoc for the four reasons.
  """
  def clean(markup) when is_binary(markup) do
    with true <- svg?(markup),
         {:ok, cleaned} <- rewrite(markup),
         true <- renders_alike?(markup, cleaned) do
      {:ok, cleaned}
    else
      # `false` from either predicate — not an SVG, or the rewrite drew
      # different pixels; neither is anything the member can do something
      # about, so both take the structural word.
      false -> {:error, :unclean}
      {:error, _reason} = refusal -> refusal
    end
  end

  def clean(_markup), do: {:error, :unclean}

  @doc """
  Whether two documents draw exactly the same pixels — the proof `clean/1` makes
  of its own rewrite, public so a test calibrates the instrument that ships
  rather than a copy of it.

  Both are rasterised through `Vutuv.Uploads.Spec.open_rotated_binary/1`, which
  vets the markup on the way (so the stored file is re-vetted here, not only at
  upload) and normalises every vector to one raster size, then fingerprinted
  with the dimensions alongside — a document that lost its size cannot pass by
  drawing fewer pixels. Hashing rather than comparing the two buffers keeps only
  one 1600px buffer (~10 MB) alive at a time.

  The cost is two librsvg parses of a document the upload has already parsed;
  measured at 8 to 17 ms for a real logo and 1.8 s for a synthetic 5.3 MB one,
  which is why it is derived at upload rather than on a render.
  """
  def renders_alike?(original, cleaned) when is_binary(original) and is_binary(cleaned) do
    case {raster(original), raster(cleaned)} do
      {{:ok, same}, {:ok, same}} -> true
      _differ -> false
    end
  end

  # Never the extension: a file called `.svg` that holds a PNG has to reach the
  # container stripper's refusal, not this parser's. `String.valid?/1` is not
  # ceremony — the `data:` scan below is a UTF-8 regex, and invalid bytes raise
  # in it.
  defp svg?(markup), do: String.valid?(markup) and Spec.svg_binary?(markup)

  defp raster(markup) do
    with {:ok, image} <- Spec.open_rotated_binary(markup),
         {:ok, pixels} <- VipsImage.write_to_binary(image) do
      {:ok, {VipsImage.width(image), VipsImage.height(image), :crypto.hash(:sha256, pixels)}}
    else
      _ -> :error
    end
  end

  ## The scanner
  #
  # The document is walked once and emitted as iodata. Every branch either
  # copies the bytes it consumed or drops them whole. `scopes` is the stack of
  # in-scope namespace bindings, pushed on an open tag and popped on a close, so
  # a prefix is resolved where it is used rather than where it was declared.
  #
  # Every region that is **kept** goes through `clean_data_uris/1` — a CDATA
  # body, a processing instruction, a text node, an attribute value — because an
  # editor picks which of them it parks a photograph in, not us. A fifth branch
  # that keeps bytes belongs on that list.

  defp rewrite(markup) do
    with {:ok, parts} <- scan(markup, [@root_scope], []),
         do: {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp scan(<<>>, _scopes, acc), do: {:ok, acc}

  defp scan(<<"<!--", rest::binary>>, scopes, acc) do
    with {_comment, tail} <- split_on(rest, "-->"), do: scan(tail, scopes, acc)
  end

  defp scan(<<"<![CDATA[", rest::binary>>, scopes, acc) do
    with {body, tail} <- split_on(rest, "]]>"),
         {:ok, clean} <- clean_data_uris(body) do
      scan(tail, scopes, ["]]>", clean, "<![CDATA[" | acc])
    end
  end

  # A declaration is only ever a DOCTYPE here, and a DOCTYPE is where an entity
  # is declared. The upload gate already refuses one (`Spec.open_rotated/1`);
  # this is the second line, because a stored file is never re-vetted.
  defp scan(<<"<!", _rest::binary>>, _scopes, _acc), do: {:error, :unclean}

  defp scan(<<"<?", rest::binary>>, scopes, acc) do
    with {body, tail} <- split_on(rest, "?>"),
         {:ok, clean} <- clean_data_uris(body) do
      scan(tail, scopes, ["?>", clean, "<?" | acc])
    end
  end

  defp scan(<<"</", rest::binary>>, [_innermost | outer], acc) when outer != [] do
    with {name, tail} <- split_on(rest, ">"),
         do: scan(tail, outer, [">", name, "</" | acc])
  end

  defp scan(<<"</", _rest::binary>>, _scopes, _acc), do: {:error, :unclean}

  defp scan(<<"<", rest::binary>>, scopes, acc) do
    with {:ok, tag} <- parse_tag(rest), do: emit_tag(tag, scopes, acc)
  end

  defp scan(binary, scopes, acc) do
    {text, tail} = split_at(binary, until_markup(binary))

    with {:ok, clean} <- clean_data_uris(text), do: scan(tail, scopes, [clean | acc])
  end

  defp until_markup(binary) do
    case :binary.match(binary, "<") do
      {position, _length} -> position
      :nomatch -> byte_size(binary)
    end
  end

  ## One element

  defp emit_tag(%{name: name, attributes: attributes} = tag, scopes, acc) do
    scope = Map.merge(hd(scopes), declarations(attributes))

    if drop?(name, scope),
      do: drop_tag(tag, scopes, acc),
      else: keep_tag(tag, scope, scopes, acc)
  end

  defp keep_tag(tag, scope, scopes, acc) do
    case attributes_iodata(tag.attributes, scope, []) do
      {:ok, kept} ->
        close = if tag.empty?, do: "/>", else: ">"
        inner = if tag.empty?, do: scopes, else: [scope | scopes]
        scan(tag.tail, inner, [close, tag.trailing, kept, tag.name, "<" | acc])

      {:error, _reason} = refusal ->
        refusal
    end
  end

  defp drop_tag(%{empty?: true} = tag, scopes, acc), do: scan(tag.tail, scopes, acc)

  defp drop_tag(tag, scopes, acc) do
    with {:ok, rest} <- skip_element(tag.tail, 1), do: scan(rest, scopes, acc)
  end

  defp attributes_iodata([], _scope, acc), do: {:ok, Enum.reverse(acc)}

  defp attributes_iodata([attribute | rest], scope, acc) do
    case split_name(attribute.name) do
      {nil, <<o, n, _rest::binary>>} when o in ~c"oO" and n in ~c"nN" ->
        {:error, :svg_event_handler}

      split ->
        if keep_attribute?(split, scope),
          do: keep_attribute(attribute, rest, scope, acc),
          else: attributes_iodata(rest, scope, acc)
    end
  end

  defp keep_attribute(attribute, rest, scope, acc) do
    case clean_data_uris(attribute.value) do
      {:ok, value} ->
        part = [attribute.space, attribute.name, attribute.separator, value, attribute.quoted]
        attributes_iodata(rest, scope, [part | acc])

      {:error, _reason} = refusal ->
        refusal
    end
  end

  ## Who belongs to which namespace

  defp declarations(attributes) do
    Enum.reduce(attributes, %{}, fn %{name: name, value: value}, acc ->
      case split_name(name) do
        {"xmlns", prefix} -> Map.put(acc, prefix, value)
        {nil, "xmlns"} -> Map.put(acc, :default, value)
        _other -> acc
      end
    end)
  end

  # `metadata` is the one SVG element dropped by name: the specification says it
  # is not rendered, and it is where every editor writes the author.
  defp drop?(name, scope) do
    {prefix, local} = split_name(name)
    namespace = element_namespace(prefix, scope)

    namespace not in @keep_ns or (namespace == @svg_ns and local == "metadata")
  end

  # An undeclared (or explicitly emptied) default namespace is read as SVG: a
  # namespace-less drawing still draws, and dropping it would be the rewrite
  # this module exists not to make.
  defp element_namespace(nil, scope) do
    case Map.get(scope, :default, "") do
      "" -> @svg_ns
      namespace -> namespace
    end
  end

  defp element_namespace(prefix, scope), do: Map.get(scope, prefix)

  # An unprefixed attribute is in no namespace at all — every SVG geometry and
  # presentation attribute is one — so it stays. `xmlns:p` leaves when `p` does.
  # It takes the already-split name, because the clause above it has to look at
  # the local part anyway (issue #2181): a script handler is the one attribute
  # neither kept nor dropped but refused, and it is recognised on the **parsed**
  # name, so the same letters in a text node stay text. Unprefixed only — `on…`
  # binds an event in no namespace, and a prefixed one leaves with its namespace
  # in any case. `on` plus one more character is the whole rule: no SVG
  # attribute begins with those two letters without being a handler, and a list
  # of the handlers there happen to be today would be a list to keep.
  defp keep_attribute?({"xmlns", prefix}, scope), do: Map.get(scope, prefix) in @keep_ns
  defp keep_attribute?({nil, _local}, _scope), do: true
  defp keep_attribute?({prefix, _local}, scope), do: Map.get(scope, prefix) in @keep_ns

  defp split_name(name) do
    case :binary.split(name, ":") do
      [prefix, local] -> {prefix, local}
      [local] -> {nil, local}
    end
  end

  ## Embedded files

  defp clean_data_uris(text) do
    case :binary.match(text, "data:") do
      :nomatch -> {:ok, text}
      _found -> rewrite_data_uris(text)
    end
  end

  defp rewrite_data_uris(text) do
    @data_uri
    |> Regex.scan(text, return: :index)
    |> Enum.reduce_while({0, []}, &splice(&1, &2, text))
    |> finish_data_uris(text)
  end

  defp splice([{start, length}, media, payload], {cursor, acc}, text) do
    head = binary_part(text, cursor, start - cursor)

    case cleaned_data_uri(slice(text, media), slice(text, payload)) do
      {:ok, replacement} -> {:cont, {start + length, [replacement, head | acc]}}
      {:error, _reason} = refusal -> {:halt, refusal}
    end
  end

  defp finish_data_uris({:error, _reason} = refusal, _text), do: refusal

  # Iodata, not a binary: every caller drops the answer straight into the
  # accumulator `rewrite/1` flattens once, so a binary here would be a second
  # copy of exactly the multi-megabyte base64 case.
  defp finish_data_uris({cursor, acc}, text) do
    tail = binary_part(text, cursor, byte_size(text) - cursor)
    {:ok, Enum.reverse(acc, [tail])}
  end

  # Only base64, and only a container `MetadataStrip` can take apart. A
  # percent-encoded payload, an embedded font, an SVG inside the SVG: none of
  # them can be proven clean, so the file they sit in is not handed out either.
  #
  # The two refusals are told apart because the member can act on each of them
  # differently (issue #2182): a payload we decoded and could not clean is a
  # **file** in the logo — a webfont, almost always — while one we could not
  # decode at all may be no file whatsoever, just a description that reads like
  # one. Nothing here can tell those two apart, and neither can the member
  # without being told which words we are reading.
  defp cleaned_data_uri(media, payload) do
    with true <- String.ends_with?(String.downcase(media), ";base64"),
         {:ok, raw} <- Base.decode64(payload, ignore: :whitespace) do
      case MetadataStrip.strip_binary(raw) do
        bytes when is_binary(bytes) -> {:ok, ["data:", media, ",", Base.encode64(bytes)]}
        _unsupported -> {:error, :svg_embedded_file}
      end
    else
      _undecodable -> {:error, :svg_unreadable_data}
    end
  end

  defp slice(text, {start, length}), do: binary_part(text, start, length)

  ## A dropped element's subtree
  #
  # Consumed rather than scanned, so nothing inside it can be emitted by
  # accident — and the constructs in which a `<` or a `>` is not markup are
  # honoured, or a `</metadata>` written inside a CDATA block would end the
  # wrong element.

  defp skip_element(<<"<!--", rest::binary>>, depth), do: skip_past(rest, "-->", depth)
  defp skip_element(<<"<![CDATA[", rest::binary>>, depth), do: skip_past(rest, "]]>", depth)
  defp skip_element(<<"<?", rest::binary>>, depth), do: skip_past(rest, "?>", depth)
  defp skip_element(<<"<!", _rest::binary>>, _depth), do: {:error, :unclean}

  defp skip_element(<<"</", rest::binary>>, depth) do
    with {_name, tail} <- split_on(rest, ">") do
      if depth == 1, do: {:ok, tail}, else: skip_element(tail, depth - 1)
    end
  end

  defp skip_element(<<"<", rest::binary>>, depth) do
    case skip_tag(rest, nil) do
      {:ok, :empty, tail} -> skip_element(tail, depth)
      {:ok, :open, tail} -> skip_element(tail, depth + 1)
      {:error, _reason} = refusal -> refusal
    end
  end

  # Reached only for content that does not start with `<`, since every form that
  # does is matched above — so the jump is always forward.
  defp skip_element(binary, depth) do
    case :binary.match(binary, "<") do
      {position, _length} ->
        skip_element(binary_part(binary, position, byte_size(binary) - position), depth)

      :nomatch ->
        {:error, :unclean}
    end
  end

  defp skip_past(rest, delimiter, depth) do
    with {_body, tail} <- split_on(rest, delimiter), do: skip_element(tail, depth)
  end

  defp skip_tag(<<>>, _quoted), do: {:error, :unclean}
  defp skip_tag(<<char, rest::binary>>, nil) when char in ~c"\"'", do: skip_tag(rest, char)
  defp skip_tag(<<char, rest::binary>>, quoted) when char == quoted, do: skip_tag(rest, nil)
  defp skip_tag(<<"/>", rest::binary>>, nil), do: {:ok, :empty, rest}
  defp skip_tag(<<">", rest::binary>>, nil), do: {:ok, :open, rest}
  defp skip_tag(<<_char, rest::binary>>, quoted), do: skip_tag(rest, quoted)

  ## Parsing one start tag
  #
  # Each piece is kept as the bytes it was, so a kept attribute is re-emitted
  # exactly — including the quote character the author chose and whatever
  # whitespace stood in front of it.

  defp parse_tag(binary) do
    {name, rest} = split_at(binary, name_length(binary, 0))

    with true <- name != "",
         {:ok, attributes, trailing, empty?, tail} <- parse_attributes(rest, []) do
      {:ok, %{name: name, attributes: attributes, trailing: trailing, empty?: empty?, tail: tail}}
    else
      _ -> {:error, :unclean}
    end
  end

  defp parse_attributes(binary, acc) do
    {space, rest} = split_at(binary, whitespace_length(binary, 0))

    case rest do
      <<"/>", tail::binary>> -> {:ok, Enum.reverse(acc), space, true, tail}
      <<">", tail::binary>> -> {:ok, Enum.reverse(acc), space, false, tail}
      <<>> -> {:error, :unclean}
      _attribute -> parse_attribute(rest, space, acc)
    end
  end

  defp parse_attribute(binary, space, acc) do
    {name, rest} = split_at(binary, name_length(binary, 0))
    {before_equals, rest} = split_at(rest, whitespace_length(rest, 0))

    case rest do
      <<"=", value::binary>> when name != "" ->
        parse_value(space, name, before_equals, value, acc)

      _malformed ->
        {:error, :unclean}
    end
  end

  defp parse_value(space, name, before_equals, binary, acc) do
    {after_equals, rest} = split_at(binary, whitespace_length(binary, 0))

    with {:ok, quoted, rest} <- take_quote(rest),
         {value, tail} <- split_on(rest, quoted) do
      attribute = %{
        space: space,
        name: name,
        separator: [before_equals, "=", after_equals, quoted],
        quoted: quoted,
        value: value
      }

      parse_attributes(tail, [attribute | acc])
    else
      _ -> {:error, :unclean}
    end
  end

  defp take_quote(<<char, rest::binary>>) when char in ~c"\"'", do: {:ok, <<char>>, rest}
  defp take_quote(_binary), do: {:error, :unclean}

  ## Byte helpers

  defp split_on(binary, delimiter) do
    case :binary.split(binary, delimiter) do
      [before, rest] -> {before, rest}
      [_only] -> {:error, :unclean}
    end
  end

  defp split_at(binary, length),
    do: {binary_part(binary, 0, length), binary_part(binary, length, byte_size(binary) - length)}

  defp whitespace_length(<<char, rest::binary>>, length) when char in @whitespace,
    do: whitespace_length(rest, length + 1)

  defp whitespace_length(_binary, length), do: length

  defp name_length(<<char, rest::binary>>, length) when char not in @name_stop,
    do: name_length(rest, length + 1)

  defp name_length(_binary, length), do: length
end
