defmodule Vutuv.WebAddress do
  @moduledoc """
  Recognizes free text that is **nothing but** a web address.

  Some sign-ups use a profile field as a billboard: the tagline is one bare
  `https://example.com/`, a tag is `www.example.com` or an email address. Such
  a value says nothing about the member, so the changesets that own those
  fields refuse it — the profile tagline (`Vutuv.Accounts.User`), a tag name
  (`Vutuv.Tags.Tag`) and the sign-up form's tag list.

  The rule deliberately applies to the **whole** value, not to addresses as
  such: a tagline that names a company site inside a sentence ("Co-Founder of
  Taxdoo (www.taxdoo.com)") is ordinary and stays valid. Only a value with no
  words of its own left over is refused.
  """

  # Link markup an address can be wrapped in: an `<a>` element, a `[url=…]…[/url]`
  # BBCode pair, a Markdown `[label](target)` link (image form included), and
  # any leftover HTML tag. The label is stripped with the link — it belongs to
  # the address, not to the member's own words, so `[Cheap Casino](https://…)`
  # is still link-only. The anchor's closing tag is matched as "any letters"
  # rather than a literal `</a>`, because the spam seen in production wrote it
  # with a Cyrillic а.
  @markup [
    ~r"<a\b[^>]*>[\s\S]*?</\p{L}+>"iu,
    ~r"\[url[^\]]*\][\s\S]*?\[/url\]"iu,
    ~r"!?\[[^\]]*\]\([^)]*\)"u,
    ~r"</?\p{L}[^>]*>"u
  ]

  # Word endings that only ever mean "a website". Deliberately a short curated
  # list rather than the whole TLD registry: several real TLDs double as
  # technology names members legitimately tag themselves with (`socket.io`,
  # `asp.net`, `node.js`, `stud.ip`, `xamarin.forms`), and rejecting those
  # would be worse than letting a domain under a rare TLD through — the scheme
  # and `www.` spellings below catch it whenever it is written out in full.
  @website_tlds ~w(com de org info biz eu ch at ru cn uk nl fr es it pl br in
                   tv shop store online site xyz top club casino bet vip)

  @addresses [
    # `https://…` and any other scheme-with-authority URL. The `://` is
    # required: a bare `scheme:` would swallow the German gender colon
    # ("Berater:innen") and turn an ordinary tagline into a link.
    ~r"\p{L}[\p{L}\d+.-]*://\S+"u,
    # A `www.` host, with or without a path.
    ~r"\bwww\.\S+"iu,
    # An email address, `mailto:` prefix included so it strips whole.
    ~r"(?:mailto:)?[\p{L}\d._%+'-]+@[\p{L}\d.-]+\.\p{L}{2,}"u,
    # A dotted host carrying a path ("mastodon.social/@someone").
    ~r"\b[\p{L}\d][\p{L}\d-]*(?:\.[\p{L}\d-]+)+/\S*"u,
    # A bare domain: no scheme, no path ("sbasf.com").
    ~r"\b[\p{L}\d][\p{L}\d-]*(?:\.[\p{L}\d-]+)*\.(?:#{Enum.join(@website_tlds, "|")})\b/?"iu
  ]

  @doc """
  Whether `text` consists of web addresses and punctuation only, with no words
  of the member's own.

  There has to be an address: blank text is `false` (an empty field is the
  business of `validate_required`), and so is text that merely has no words in
  it, like `"-"` or `"???"` — junk, but nothing this rule should claim is a
  web address.

      iex> Vutuv.WebAddress.link_only?("https://www.example.com/")
      true

      iex> Vutuv.WebAddress.link_only?("Co-Founder of Taxdoo (www.taxdoo.com)")
      false

      iex> Vutuv.WebAddress.link_only?("node.js")
      false

      iex> Vutuv.WebAddress.link_only?("???")
      false
  """
  def link_only?(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        false

      trimmed ->
        stripped = strip_addresses(trimmed)
        stripped != trimmed and not has_words?(stripped)
    end
  end

  def link_only?(_), do: false

  # Every address and every piece of link markup removed, so what remains is
  # whatever the member wrote themselves.
  defp strip_addresses(text) do
    Enum.reduce(@markup ++ @addresses, text, &Regex.replace(&1, &2, " "))
  end

  defp has_words?(text), do: Regex.match?(~r/[\p{L}\p{N}]/u, text)
end
