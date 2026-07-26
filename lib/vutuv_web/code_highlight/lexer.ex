defmodule VutuvWeb.CodeHighlight.Lexer do
  @moduledoc """
  Splits a plain-text code block into `{class, text}` tokens for
  `VutuvWeb.CodeHighlight`, which escapes them and wraps each classed run in a
  `<span>`. `class` is `nil` for text that gets no colour, otherwise one of
  `:comment`, `:string`, `:number`, `:keyword`, `:type`, `:literal`, `:tag`,
  `:attr` or `:meta`.

  Concatenating every token's text reproduces the input byte for byte — the
  caller relies on that, so a token must never drop or rewrite a character.

  This is a scanner, not a parser: it recognises comments, strings, numbers and
  known words, which is what makes a code block readable at a glance, and it
  stops there. Two deliberate limits keep a malformed block from spoiling the
  rest of the page: an unterminated `"`/`'` string ends at its line (so one
  stray quote cannot paint everything after it), and an unclosed block comment
  simply runs to the end of the block.

  Two lexers, picked by the language's `:family`: `code/2` (the general
  scanner) and `markup/1` (tag and attribute names, for HTML/XML). A `diff`
  fence never reaches here — `VutuvWeb.Markdown.highlight_diff_blocks/1` owns
  that one and renders it as real diff rows (issue #1108).
  """

  @doc "Tokenize `code` for the given language configuration."
  def tokens(code, %{family: :markup}), do: markup(code)
  def tokens(code, config), do: code(code, config)

  ## The general code scanner

  defp code(source, config), do: scan(source, config, 0, 0, [])

  defp scan(source, _config, index, run, acc) when index >= byte_size(source) do
    Enum.reverse(plain(acc, source, run, index))
  end

  defp scan(source, config, index, run, acc) do
    rest = from(source, index)

    case match(rest, config) do
      {nil, length} ->
        scan(source, config, index + length, run, acc)

      {class, length} ->
        acc = [{class, binary_part(source, index, length)} | plain(acc, source, run, index)]
        scan(source, config, index + length, index + length, acc)

      nil ->
        scan(source, config, index + char_bytes(rest), run, acc)
    end
  end

  # A word is always consumed whole, even when it is not a keyword — otherwise
  # the scanner would restart one byte in and find `if` inside `xif`.
  defp match(rest, config) do
    comment(rest, config) || triple(rest, config.triples) || string(rest, config.quotes) ||
      prefixed(rest, config) || number(rest) || word(rest, config)
  end

  defp comment(rest, config), do: line_comment(rest, config.line) || block_comment(rest, config)

  defp line_comment(_rest, []), do: nil

  defp line_comment(rest, [opener | rest_openers]) do
    if String.starts_with?(rest, opener) do
      {:comment, until_newline(rest)}
    else
      line_comment(rest, rest_openers)
    end
  end

  defp block_comment(_rest, %{block: nil}), do: nil

  defp block_comment(rest, %{block: {opener, closer}}) do
    if String.starts_with?(rest, opener) do
      {:comment, until_closed(rest, byte_size(opener), closer)}
    end
  end

  defp triple(_rest, []), do: nil

  defp triple(rest, [delimiter | rest_delimiters]) do
    if String.starts_with?(rest, delimiter) do
      {:string, until_closed(rest, byte_size(delimiter), delimiter)}
    else
      triple(rest, rest_delimiters)
    end
  end

  defp string(<<quote, _::binary>> = rest, quotes) do
    if quote in quotes, do: {:string, string_bytes(rest, quote)}
  end

  defp string(_rest, _quotes), do: nil

  defp prefixed(<<sigil, next, _::binary>> = rest, config) do
    if sigil in config.prefixed and word_start?(next) do
      {:literal, word_bytes(rest, 1, config)}
    end
  end

  defp prefixed(_rest, _config), do: nil

  defp number(<<digit, _::binary>> = rest) when digit in ?0..?9,
    do: {:number, number_bytes(rest, 1)}

  defp number(_rest), do: nil

  defp word(<<first, _::binary>> = rest, config) do
    if word_start?(first) or first in config.word_extra do
      length = word_bytes(rest, 0, config)
      {classify(binary_part(rest, 0, length), config), length}
    end
  end

  defp word(_rest, _config), do: nil

  defp classify(text, config) do
    key = if config.ci, do: String.downcase(text), else: text

    cond do
      MapSet.member?(config.keywords, key) -> :keyword
      MapSet.member?(config.builtins, key) -> :type
      true -> nil
    end
  end

  ## Markup (HTML, XML and friends)

  defp markup(source), do: markup_scan(source, 0, 0, [])

  defp markup_scan(source, index, run, acc) when index >= byte_size(source) do
    Enum.reverse(plain(acc, source, run, index))
  end

  defp markup_scan(source, index, run, acc) do
    rest = from(source, index)

    case markup_match(rest) do
      {tokens, length} ->
        acc = Enum.reverse(tokens) ++ plain(acc, source, run, index)
        markup_scan(source, index + length, index + length, acc)

      nil ->
        markup_scan(source, index + char_bytes(rest), run, acc)
    end
  end

  defp markup_match(rest) do
    cond do
      String.starts_with?(rest, "<!--") -> one(:comment, rest, until_closed(rest, 4, "-->"))
      String.starts_with?(rest, "<!") -> one(:meta, rest, until_closed(rest, 2, ">"))
      String.starts_with?(rest, "<?") -> one(:meta, rest, until_closed(rest, 2, ">"))
      tag_start?(rest) -> tag(rest)
      entity?(rest) -> one(:literal, rest, until_closed(rest, 1, ";"))
      true -> nil
    end
  end

  defp one(class, rest, length), do: {[{class, binary_part(rest, 0, length)}], length}

  defp tag_start?(<<"</", next, _::binary>>), do: word_start?(next)
  defp tag_start?(<<"<", next, _::binary>>), do: word_start?(next)
  defp tag_start?(_rest), do: false

  # An entity is only worth marking when it really closes; `until_closed/3`
  # falls back to the whole block, so check for the `;` first.
  defp entity?(<<"&", next, _::binary>> = rest),
    do: (word_start?(next) or next == ?#) and :binary.match(rest, ";") != :nomatch

  defp entity?(_rest), do: false

  defp tag(rest) do
    length = tag_bytes(rest, 1)
    {open, name_and_attrs} = split_tag_open(binary_part(rest, 0, length))
    {name, attrs} = split_name(name_and_attrs)

    {[{nil, open}, {:tag, name} | tag_attrs(attrs, [])], length}
  end

  defp split_tag_open(<<"</", rest::binary>>), do: {"</", rest}
  defp split_tag_open(<<"<", rest::binary>>), do: {"<", rest}

  defp tag_attrs(<<>>, acc), do: Enum.reverse(acc)

  defp tag_attrs(<<first, _::binary>> = rest, acc) do
    cond do
      first in [?", ?'] ->
        length = string_bytes(rest, first)
        tag_attrs(from(rest, length), [{:string, binary_part(rest, 0, length)} | acc])

      name_char?(first) ->
        {name, tail} = split_name(rest)
        tag_attrs(tail, [{:attr, name} | acc])

      true ->
        tag_attrs(from(rest, 1), [{nil, <<first>>} | acc])
    end
  end

  # The byte length of a whole tag, up to and including its `>`. Quoted
  # attribute values are skipped so a `>` inside one does not end it early.
  defp tag_bytes(rest, index) when index >= byte_size(rest), do: byte_size(rest)

  defp tag_bytes(rest, index) do
    case :binary.at(rest, index) do
      ?> ->
        index + 1

      quote when quote in [?", ?'] ->
        tag_bytes(rest, index + string_bytes(from(rest, index), quote))

      _ ->
        tag_bytes(rest, index + 1)
    end
  end

  defp split_name(rest), do: split_name(rest, 0)

  defp split_name(rest, index) when index >= byte_size(rest), do: {rest, <<>>}

  defp split_name(rest, index) do
    if name_char?(:binary.at(rest, index)) or (index > 0 and :binary.at(rest, index) in ?0..?9) do
      split_name(rest, index + 1)
    else
      {binary_part(rest, 0, index), from(rest, index)}
    end
  end

  defp name_char?(char), do: word_start?(char) or char in ~c"-:.@#"

  ## Shared scanning helpers

  defp plain(acc, _source, run, index) when run >= index, do: acc
  defp plain(acc, source, run, index), do: [{nil, binary_part(source, run, index - run)} | acc]

  defp from(binary, index), do: binary_part(binary, index, byte_size(binary) - index)

  defp char_bytes(<<byte, _::binary>>) when byte < 0xC0, do: 1
  defp char_bytes(<<byte, _::binary>>) when byte < 0xE0, do: 2
  defp char_bytes(<<byte, _::binary>>) when byte < 0xF0, do: 3
  defp char_bytes(_rest), do: 4

  defp until_newline(rest) do
    case :binary.match(rest, "\n") do
      {position, _length} -> position
      :nomatch -> byte_size(rest)
    end
  end

  # From `after_opener` to the end of `closer`, or the whole rest when the
  # closer never comes (an unterminated comment or heredoc).
  defp until_closed(rest, after_opener, _closer) when byte_size(rest) <= after_opener,
    do: byte_size(rest)

  defp until_closed(rest, after_opener, closer) do
    scope = {after_opener, byte_size(rest) - after_opener}

    case :binary.match(rest, closer, scope: scope) do
      {position, length} -> position + length
      :nomatch -> byte_size(rest)
    end
  end

  defp string_bytes(rest, quote), do: string_bytes(rest, quote, 1, quote == ?`)

  defp string_bytes(rest, _quote, index, _multiline?) when index >= byte_size(rest),
    do: byte_size(rest)

  defp string_bytes(rest, quote, index, multiline?) do
    case :binary.at(rest, index) do
      ?\\ -> string_bytes(rest, quote, index + 2, multiline?)
      ^quote -> index + 1
      ?\n when not multiline? -> index
      _ -> string_bytes(rest, quote, index + 1, multiline?)
    end
  end

  defp number_bytes(rest, index) when index >= byte_size(rest), do: index

  defp number_bytes(rest, index) do
    case number_step(rest, index, :binary.at(rest, index)) do
      :halt -> index
      step -> number_bytes(rest, index + step)
    end
  end

  # How far a numeric literal reaches past `index`. Letters and `_` are in
  # (`0xFF`, `1_000`, `10px`); a `.` only when a digit follows, so `1..2` is a
  # range and not one long number; a sign only right after the `e` of an
  # exponent.
  defp number_step(_rest, _index, char) when char in ?0..?9 or char == ?_, do: 1
  defp number_step(_rest, _index, char) when char in ?a..?z or char in ?A..?Z, do: 1
  defp number_step(rest, index, ?.), do: if(digit_at?(rest, index + 1), do: 2, else: :halt)

  defp number_step(rest, index, sign) when sign in [?+, ?-],
    do: if(exponent_at?(rest, index), do: 1, else: :halt)

  defp number_step(_rest, _index, _char), do: :halt

  defp digit_at?(rest, index),
    do: index < byte_size(rest) and :binary.at(rest, index) in ?0..?9

  defp exponent_at?(rest, index),
    do: :binary.at(rest, index - 1) in [?e, ?E] and digit_at?(rest, index + 1)

  defp word_bytes(rest, index, _config) when index >= byte_size(rest), do: index

  defp word_bytes(rest, index, config) do
    char = :binary.at(rest, index)

    cond do
      word_char?(char) or char in config.word_extra -> word_bytes(rest, index + 1, config)
      char in config.word_suffix -> index + 1
      true -> index
    end
  end

  defp word_start?(char), do: char in ?a..?z or char in ?A..?Z or char == ?_
  defp word_char?(char), do: word_start?(char) or char in ?0..?9
end
