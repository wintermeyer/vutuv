defmodule VutuvWeb.Markdown do
  @moduledoc """
  Chat-style Markdown rendering for user-generated text (messages).

  Pipeline: `<` is escaped first, so raw HTML a user types shows up as literal
  text instead of becoming markup (and Earmark never enters its HTML-block mode,
  which would swallow the Markdown around it). Bare `http(s)://` URLs become
  Markdown links whose display text is shortened to the host and its first path
  directory — two directories for GitHub and this installation's own host, whose
  meaningful unit is two segments deep (long URLs would wreck chat bubbles);
  trailing sentence punctuation and unbalanced `)` stay outside the
  link. Earmark renders the Markdown (bold, italics, links, inline code, lists,
  quotes; a single newline becomes a `<br>` in chat/messages, but **posts**
  reflow soft-wrapped lines instead — see `render_pipeline/2`'s `breaks:` note),
  HtmlSanitizeEx strips anything dangerous as a second line of defence
  (`javascript:` hrefs etc.), and links open in a new tab. A fenced code block
  is then named and coloured (`VutuvWeb.CodeHighlight`), and a `diff` fence's
  lines are marked up as added / removed / context so it reads as a diff
  (`VutuvWeb.CodeHighlight.Diff`).

  **Images**: only a post may embed pictures, and only its **own uploaded
  attachments** (`render_post/2`'s whitelist) — a hotlinked remote image would
  leak every reader's IP, so `render_pipeline/1` drops every `<img>` the
  Markdown itself produces, and the allowed references are re-injected from
  known-safe parts afterwards. A message body stays image-free
  (`Vutuv.MarkdownContent.validate_no_images/2` plus the same pipeline drop).
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Fediverse
  alias Vutuv.Mentions
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts.PostImage
  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.VerifiedLinks
  alias Vutuv.Tags
  alias VutuvWeb.CodeHighlight
  alias VutuvWeb.CodeHighlight.Diff
  alias VutuvWeb.CodeHighlight.Fences
  alias VutuvWeb.Markdown.Footnotes
  alias VutuvWeb.UserHelpers

  @url_display_max 40
  # `…` included: remote (Mastodon) text is length-capped with a trailing
  # ellipsis that must not become part of a link target.
  @trailing_punct ~w(. , ; : ! ? …)
  # A single `[^\s<>]+` autolink match longer than this is emitted verbatim
  # instead of being linked. No real URL comes close (browsers cap around 2K),
  # so this only ever rejects a pathological unbroken run — a hard ceiling on
  # the work `split_trailing_punct/1` can be asked to do per match, independent
  # of that function already being linear.
  @autolink_max 2_000
  @preview_limit 1000
  # The code regions of a Markdown source — fenced blocks first, then inline
  # code spans — as one capture, so `Regex.split(include_captures: true)`
  # alternates non-code / code chunks. Used by `map_outside_code/2`.
  @code_region ~r/(```[\s\S]*?```|~~~[\s\S]*?~~~|``[^`]*``|`[^`\n]*`)/
  # How much of a text selection a reply may quote (issue #1114). A paragraph
  # fits; marking half the page does not, and the excerpt rides in a URL.
  @quote_max_length 500
  # When a whole block would overflow the preview, keep a word-cut of it (so a
  # one-line intro above a long block doesn't leave a one-line preview) — but
  # only if at least this many characters of budget remain, else just stop.
  @preview_min_block 200
  # A one-line preview is truncated by the row it sits in long before this, so
  # the cap is only there to keep a whole essay out of a list payload.
  @preview_line_length 200
  @inline_image ~r/!\[([^\]]*)\]\(([^)\s]+)\)/
  # The alignment fragments an inline image src may carry (`#left` floats the
  # picture beside the text, `#right` mirrored, `#center` centers it; no
  # fragment = full text width). Parsed off the URL at render time and turned
  # into a `post-inline-image--*` modifier class — the served src stays clean.
  @image_alignments ~w(left right center)

  # A fediverse handle `@user@host.tld`, a local `@handle` mention, or a
  # `#hashtag`. The grammar itself lives in `Vutuv.Mentions` (the single source
  # shared by rendering, mention-existence validation and the rename rewrite),
  # so it can never drift from what those paths detect. The leading `@`/`#` must
  # not sit mid-token (no email `a@b`, no `/path#frag`); the fediverse form is
  # tried **first**, so `@a@b.social` is read as one whole address rather than
  # the member `@a` plus loose text, and the **host** then decides where it
  # points; handles/tags match permissively and are validated against the
  # DB by `linkify_entities/1`. Captures: 1 = fediverse user, 2 = fediverse
  # host, 3 = local handle, 4 = hashtag (exactly one kind is set per hit).
  @entity Mentions.entity_regex()

  # Inside these elements an entity is left as plain text (a handle/hashtag in a
  # code span/block is sample text, and we never nest a link inside a link).
  @entity_skip_tags ~w(a code pre)

  @doc "Render untrusted Markdown to safe HTML (`Phoenix.HTML.safe()`)."
  def render(text) when is_binary(text) do
    text
    |> render_pipeline()
    |> open_links_in_new_tab()
    |> linkify_entities()
    |> Phoenix.HTML.raw()
  end

  def render(_), do: Phoenix.HTML.raw("")

  @doc """
  Render a post's Markdown (`Phoenix.HTML.safe()`).

  Same pipeline as `render/1`, plus inline images: `![alt](url)` renders as
  an `<img>` **only** when `url` is a served version of one of the post's
  own attachments (`images` — pass the viewer-appropriate set, so an
  unreleased picture is simply absent for strangers). Everything else that
  would become an image — hotlinked remote pictures (a tracking hole: every
  reader's IP would leak to a third party), other posts' attachments, raw
  HTML — is dropped or stays escaped text. An empty Markdown alt is filled
  from the attachment's stored alt text, and a `#left`/`#right`/`#center`
  fragment on the url becomes an alignment modifier class.

  Mechanics: allowed references are swapped for unguessable plain-text
  markers *before* rendering, every `<img>` the pipeline produces is
  stripped *after* sanitizing, and the markers are then replaced with
  `<img>` tags built here from known-safe parts.

  `:verified_links` (opts) carries **this post author's** proven webpages
  (`Vutuv.Profiles.VerifiedLinks.of/1`); a link in the body that points at
  one of them earns the small verified mark — see
  `mark_verified_author_links/2`. Omit it and nothing is marked, which is
  also what an installation with `:verify_user_links` off gets: no member
  has a verified link there, so the list is always empty.

  `:mention_form` (opts) picks how a mention of one of our own accounts is
  **written**: `:local` (the default) shortens an address on our host to the
  bare handle, `:address` spells a bare handle out in full. Neither touches the
  stored body — see `Vutuv.Mentions.to_local_form/1` for why each environment
  wants the other one.

  `:image_query` (opts) is a `(image -> query | nil)` appended to each inline
  picture's URL, for a caller serving this HTML where the reader brings no
  session: the Mastodon adapter passes the same `VutuvWeb.RemoteMediaToken`
  capability it puts on the attachments (issue #1647). Omit it and the
  canonical URL stands, which is what the website wants — there the session
  answers. It does **not** absolutize; a caller rendering into a standalone
  context runs `absolutize_html/3` over the result, as RSS and the federated
  Note do.
  """
  def render_post(text, images, opts \\ [])

  def render_post(text, images, opts) when is_binary(text) and is_list(images) do
    {prepared, replacements} =
      extract_inline_images(text, images, Keyword.get(opts, :image_query))

    prepared
    |> render_pipeline(breaks: false)
    |> open_links_in_new_tab()
    |> mark_verified_author_links(Keyword.get(opts, :verified_links, []))
    |> linkify_entities(:all, Keyword.get(opts, :mention_form, :local))
    |> inject_inline_images(replacements)
    |> Phoenix.HTML.raw()
  end

  def render_post(_text, _images, _opts), do: Phoenix.HTML.raw("")

  @doc """
  Render **remote** plain text — a Mastodon post reduced to text by
  `Vutuv.Mastodon.text_content/1` — with the same treatment a member post
  gets, minus what must not apply to a foreign namespace:

    * bare URLs autolink (display-truncated), Markdown formatting renders,
      everything is sanitized — the same `render_pipeline/1` as posts;
    * every `<img>` is dropped: there is no own-attachment whitelist for
      remote content, and a hotlink would leak each reader's IP;
    * `#hashtags` link to our tag pages through the same non-empty-tag gate;
    * a fully-qualified `@user@host` fediverse handle links to that remote
      account (it unambiguously names one), the same as in a member post — and
      an address on **our** host names one of our members just as
      unambiguously, so it links to that profile (issue #1560);
    * bare `@mentions` deliberately stay plain text — a Mastodon `@name` names
      an account in the fediverse, not the vutuv member who happens to share
      the handle, so linking it would point at the wrong person;
    * every link that leaves the site is marked `ugc nofollow` — see
      `mark_foreign_links/1`.

  Returns an HTML **string** (not `safe`): the caller renders it with
  `raw/1`; it is sanitized exactly like member-post HTML.
  """
  def render_remote(text) when is_binary(text) do
    text
    |> render_pipeline()
    |> open_links_in_new_tab()
    |> linkify_entities(:hashtags_only)
    |> mark_foreign_links()
  end

  def render_remote(_), do: ""

  @doc """
  Marks every outbound link in rendered **remote** content `ugc nofollow`.

  A cached post is somebody else's text sitting on our domain, and the links in
  it are their editorial choice, not ours. `ugc` is the value search engines
  define for exactly that (user-generated content we host but did not write) and
  `nofollow` says we are not vouching for the destination — without them a
  spammer's post, boosted into one reader's feed, would hand its link our
  ranking signal from every public page that shows the card (a tag timeline, a
  member's reshare on their profile).

  It rewrites the `rel` the two link builders above have already written
  (`open_links_in_new_tab/1` for URLs in the body, `linkify_entities/2` for a
  `@user@host` handle), so the marker cannot be forgotten on one of them. Links
  to **our own** pages carry no `rel` at all — a `#hashtag` resolves to
  `/tags/:slug`, an address on our own host to that member's profile — so they
  are left alone: nofollowing our own pages would throw away the internal
  linking they exist for.
  """
  def mark_foreign_links(html) when is_binary(html) do
    String.replace(
      html,
      ~s(rel="noopener noreferrer"),
      ~s(rel="ugc nofollow noopener noreferrer")
    )
  end

  ## The author's own, proven webpages (issue #1246)

  # One rendered anchor: its opening tag, its label, its closing tag. Anchors
  # never nest, so the lazy `.*?` really does stop at this link's own `</a>`;
  # `s` lets a label span lines.
  @anchor ~r{(<a\s[^>]*>)(.*?)(</a>)}s

  @doc """
  Marks every link in rendered post HTML that points at a webpage the post's
  **author has proved is theirs** (`Vutuv.Profiles.LinkVerification`, issue
  #1246) with the small emerald ✓ the profile's Links card uses.

  `verified_links` are that one author's verified links and nothing else:
  verification carries no uniqueness constraint, so a global lookup would put
  a stranger's proof on this member's post. What each proof covers — a whole
  host or a single page — is `Vutuv.Profiles.VerifiedLinks`' decision; this
  function only asks it about each anchor's `href`.

  Runs on the already-rendered, sanitized HTML (after
  `open_links_in_new_tab/1`), so a URL inside a code span or a fenced block is
  never marked: the pipeline turned it into escaped text, not an anchor. The
  mark goes **inside** the anchor, after the label, which keeps it out of
  `linkify_entities/2`'s reach (that pass skips everything inside an `a`) and
  makes it part of the link a reader clicks rather than a stray glyph beside
  it.

  The author's own anchor text is left exactly as written — the words in
  their sentence, never the profile entry's label. The mark's `title` /
  `aria-label` names the proven address instead, escaped, so the value can
  never break out of the attribute.
  """
  def mark_verified_author_links(html, []) when is_binary(html), do: html

  def mark_verified_author_links(html, verified_links)
      when is_binary(html) and is_list(verified_links) do
    Regex.replace(@anchor, html, fn whole, open_tag, label, close_tag ->
      case matched_link(open_tag, verified_links) do
        %Url{} = link -> open_tag <> glue_mark(label, verified_mark_html(link)) <> close_tag
        nil -> whole
      end
    end)
  end

  # The end of the label and the mark, tied into one unbreakable box.
  #
  # Chrome and Firefox treat the mark's `<svg>` as an atomic inline, and UAX #14
  # allows a line break in front of one — so a link that happened to end flush
  # with the line put the tick on the next line by itself, with nothing else on
  # it (reported on #1307). Safari does not break there, which is why the report and
  # the screenshot answering it disagreed. A word joiner (U+2060) between the
  # two is the textbook fix and does nothing in Chrome (measured); only
  # `white-space: nowrap` closes that break opportunity, hence
  # `.verified-author-glue` (assets/css/components.css).
  #
  # Only the label's TRAILING WORD joins the mark, capped at @glue_chars,
  # because `nowrap` also suspends `overflow-wrap`: gluing a whole address in
  # one box costs a phone's post column its wrapping, and a 40-character
  # display (`@url_display_max`) then pushes the page sideways — measured at
  # 15px of horizontal scroll in a 310px column, the very thing
  # `mobile_overflow_test.exs` guards. A short tail can always break away from
  # the text before it, so nothing overflows and the tick still has a word to
  # sit beside.
  @glue_chars 12

  # The tail must be plain text: `<` `>` keep the slice out of markup and `&`
  # `;` out of an HTML entity, either of which would corrupt the label. A label
  # with no such tail (it ends in a tag, or in an entity) simply keeps the bare
  # mark — no real link label looks like that.
  @glue_tail ~r/[^\s<>&;]{1,#{@glue_chars}}\z/u

  defp glue_mark(label, mark) do
    case Regex.run(@glue_tail, label) do
      [tail] ->
        String.replace_suffix(
          label,
          tail,
          ~s(<span class="verified-author-glue">) <> tail <> mark <> "</span>"
        )

      nil ->
        label <> mark
    end
  end

  @doc """
  The author's proven webpages a post body actually links to, in body order
  and without repeats — what the agent-format siblings of the permalink
  report (`VutuvWeb.AgentDocs.PostDoc`).

  It renders the body and walks the same anchors `mark_verified_author_links/2`
  marks, so "which links count" is decided in exactly one place: a URL in a
  code fence is not a link here either, and a Markdown link target counts the
  same as a bare URL.
  """
  def verified_author_links(text, verified_links)
      when is_binary(text) and is_list(verified_links) and verified_links != [] do
    @anchor
    |> Regex.scan(render_pipeline(text, breaks: false), capture: :all_but_first)
    |> Enum.map(fn [open_tag | _rest] -> matched_link(open_tag, verified_links) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def verified_author_links(_text, _verified_links), do: []

  # The proven link this anchor points at, or nil. The href arrives
  # HTML-escaped (the sanitizer wrote it), so it is decoded before parsing —
  # `&amp;` in a query string is an ampersand, not three extra characters.
  defp matched_link(open_tag, verified_links) do
    case Regex.run(~r/\shref="([^"]*)"/, open_tag, capture: :all_but_first) do
      [href] -> href |> decode_escapes() |> VerifiedLinks.match(verified_links)
      _no_href -> nil
    end
  end

  # The same emerald ✓ as `VutuvWeb.UI.verified_mark/1`, written as a string
  # because this stage works on rendered HTML rather than HEEx. Icon-only, so
  # it carries the whole statement in its accessible name; the sizing and
  # colour live in `.verified-author-link` (assets/css/components.css).
  defp verified_mark_html(%Url{} = link) do
    label =
      escape(
        gettext("Verified webpage of the author (%{address})",
          address: VerifiedLinks.address(link)
        )
      )

    # `width`/`height` are a floor, not the design: an inline SVG with only a
    # viewBox falls back to 300×150 px where the stylesheet does not reach, and
    # `.verified-author-link`'s `width: 1em` outranks a presentation attribute
    # anyway, so the real sizing still lives in the CSS.
    ~s(<svg class="verified-author-link" width="16" height="16" ) <>
      ~s(viewBox="0 0 20 20" fill="currentColor" ) <>
      ~s(role="img" aria-label="#{label}"><title>#{label}</title>) <>
      ~s(<path fill-rule="evenodd" d="M16.704 4.153a.75.75 0 0 1 .143 1.052l-8 10.5a.75.75 0 0 1-1.127.075l-4.5-4.5a.75.75 0 0 1 1.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 0 1 1.05-.143Z" clip-rule="evenodd"/></svg>)
  end

  @doc """
  Split remote plain text into `{body, hashtags}`, lifting the closing
  hashtag line off the end.

  A post on Mastodon and its cousins routinely ends in a line that is nothing
  but hashtags — `#CSD #Anschlag #Berlin` — because over there a tag *is* a
  word in the text. Here a tag is a chip below the post, so that line arrived
  as a run of blue words in the middle of the card's prose and read like a
  sentence that stopped making sense. The card renders the returned hashtags
  as `<.chip>` pills instead (`VutuvWeb.PostComponents`), which is the same
  thing a member's own post does with its tags.

  Only a **closing** run is taken: walking the text back to front, every line
  that consists solely of hashtags is lifted (blank lines between them go
  too), and the walk stops at the first line carrying anything else. A hashtag
  inside a sentence, or a hashtag line the author wrote in the *middle* of a
  post, therefore stays exactly where it was and still links through
  `render_remote/1`. Hashtags come back in reading order, in the case the
  author typed, with repeats dropped case-insensitively.

  The grammar is `Vutuv.Mentions.hashtag_token_regex/0`, so a line splits on
  exactly what the body's own `#hashtag` linking reads — `#München` is an
  ordinary German hashtag and a line holding one must split like any other.
  (It used to carry its own wider class, because the shared grammar was
  ASCII-only; that is no longer true, and two Unicode classes had already
  drifted apart on `\\p{N}` against `\\p{Nd}`.) Whether a pill then *links* is a separate
  question the caller asks `Vutuv.Tags.linkable_slugs/1` — the same gate the
  body's `#hashtag` linking uses, so a pill links exactly where the inline
  hashtag would have.
  """
  def split_trailing_hashtags(text) when is_binary(text) do
    if String.contains?(text, "#") do
      {kept, hashtags} =
        text |> String.split("\n") |> Enum.reverse() |> take_trailing_hashtag_lines([])

      {kept |> Enum.join("\n") |> String.trim_trailing(),
       Enum.uniq_by(hashtags, &String.downcase/1)}
    else
      {text, []}
    end
  end

  def split_trailing_hashtags(_), do: {"", []}

  # Walks the lines back to front. A blank line is passed over rather than
  # ended on: the hashtag line is nearly always separated from the prose by
  # one, and it would otherwise stop the walk before the tags are reached.
  # Those blanks are simply dropped — whatever prose survives is trimmed at the
  # end anyway, so a text with no closing hashtag line comes back unchanged.
  defp take_trailing_hashtag_lines([], hashtags), do: {[], hashtags}

  defp take_trailing_hashtag_lines([line | above], hashtags) do
    cond do
      String.trim(line) == "" -> take_trailing_hashtag_lines(above, hashtags)
      hashtag_line?(line) -> take_trailing_hashtag_lines(above, hashtags_in(line) ++ hashtags)
      true -> {Enum.reverse([line | above]), hashtags}
    end
  end

  # `Vutuv.Mentions` owns what a hashtag is; this asks it of a whole token.
  # Punctuation is not part of a hashtag, so a line like "Mehr dazu: #Berlin."
  # keeps its full stop and is therefore not a hashtag line — which is right,
  # it is a sentence.
  @hashtag_token Mentions.hashtag_token_regex()

  defp hashtag_line?(line) do
    case String.split(line, ~r/\s+/u, trim: true) do
      [] -> false
      tokens -> Enum.all?(tokens, &Regex.match?(@hashtag_token, &1))
    end
  end

  defp hashtags_in(line) do
    line
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(&String.trim_leading(&1, "#"))
  end

  @doc """
  Flatten Markdown to **plain text**: the same pipeline a post body runs,
  then the tags dropped and the escapes decoded.

  For the compact one-line contexts that quote a post as a reference rather
  than render it — the /notifications "Your post:" breadcrumb above a reply
  and its handle-change list — where real HTML would nest links inside the
  row's own link and stack block elements into a `line-clamp-1`. Formatting
  markers disappear instead of being shown (`**bold**` reads as `bold`), a
  link keeps its label, and blocks become plain line breaks.

  Entities are **not** linkified, so this costs no DB query. An address on our
  own host is still shortened to the bare handle
  (`Vutuv.Mentions.to_local_form/1`), the same as in the rendered body: these
  are the surfaces that quote a post *inside* vutuv, and a tab title has less
  room for a host than anything else on the site.
  """
  def to_plain_text(text) when is_binary(text) do
    text |> Mentions.to_local_form() |> render_pipeline() |> html_to_plain_text()
  end

  def to_plain_text(_), do: ""

  @doc """
  The flattening half of `to_plain_text/1`, on HTML **one of our own renderers
  produced**: block ends become line breaks, tags are dropped and the escapes
  decoded.

  Split out for `VutuvWeb.EmailMarkdown.to_text/1`, which runs the email
  renderer (full URLs, real links) rather than the post pipeline and expands
  each link's target before flattening. Only feed it already-sanitized HTML —
  on arbitrary input the tag-stripping regex is not a sanitizer.
  """
  def html_to_plain_text(html) when is_binary(html) do
    html
    |> String.replace(~r{<br\s*/?>}i, "\n")
    |> String.replace(~r{</(?:p|li|h[1-6]|blockquote|tr|div)>}i, "\n")
    # Every `<…>` left is a tag: the pipeline escaped typed HTML to `&lt;` a
    # step earlier, so this can never eat body text.
    |> String.replace(~r/<[^>]*>/, "")
    |> decode_escapes()
    |> normalize_lines()
  end

  @doc """
  Flatten Markdown to the **single line** a list row previews it with: the
  messages sidebar's last-message line and the `preview` field of the API's
  conversation list.

  `to_plain_text/1` plus the block breaks folded into spaces, so a message
  whose first line is short still fills the row, and capped at
  #{@preview_line_length} characters (the row truncates far earlier; the cap
  keeps a long body out of the payload).

  Returns `""` for a body that isn't a string, so a `nil` preview can be
  passed straight in.
  """
  def to_preview_line(text) when is_binary(text) do
    text
    |> to_plain_text()
    |> String.replace("\n", " ")
    |> String.slice(0, @preview_line_length)
  end

  def to_preview_line(_), do: ""

  # Earmark lays its HTML out with whitespace of its own (a newline after every
  # opening `<p>`, indented list items, blank lines between tags), which turns
  # into stray indentation and empty lines once the tags are gone. Trim each
  # line and drop the empty ones, so what is left is the words in block order.
  # Long paragraphs are never re-wrapped by Earmark, so no sentence is broken
  # by this.
  defp normalize_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @doc """
  Turn a plain-text excerpt into Markdown **blockquote source** — what the reply
  composer opens with when the reader marked part of the post before pressing
  Reply (issue #1114).

  The excerpt comes from a browser text selection, so it arrives with the DOM's
  own line breaks and indentation: each line is trimmed and prefixed with the
  quote marker, and a blank line keeps the quote open across a paragraph break
  instead of ending it. The whole excerpt is capped at #{@quote_max_length}
  characters — cut back to the last whole word and closed with an ellipsis — so
  one selection can neither fill the answer nor bloat the URL that carries it.
  The trailing blank line puts the cursor below the quote, where the answer goes.

  Returns `nil` when there is nothing to quote, so a raw query parameter can be
  passed straight in.
  """
  def blockquote(text) when is_binary(text) do
    case text |> String.trim() |> cut_excerpt() do
      "" ->
        nil

      excerpt ->
        excerpt
        |> String.split(["\r\n", "\n", "\r"])
        |> Enum.map_join("\n", &quote_line/1)
        |> Kernel.<>("\n\n")
    end
  end

  def blockquote(_), do: nil

  # A blank line inside a blockquote ends it, so an empty line keeps the marker
  # and becomes a paragraph break within the quote.
  defp quote_line(line) do
    case String.trim(line) do
      "" -> ">"
      trimmed -> "> " <> trimmed
    end
  end

  # Cut back to the last whitespace so the quote never ends mid-word; a single
  # run too long to cut back (a pasted token, a language that doesn't space its
  # words) is cut hard rather than thrown away. The `s` flag lets the greedy
  # `.*` reach across line breaks, so the last word of a multi-line selection is
  # the one dropped.
  defp cut_excerpt(text) do
    if String.length(text) <= @quote_max_length do
      text
    else
      cut = String.slice(text, 0, @quote_max_length)

      case Regex.run(~r/^(.*)\s\S*$/su, cut, capture: :all_but_first) do
        [head] -> head <> " …"
        nil -> cut <> " …"
      end
    end
  end

  # The escapes Earmark and the sanitizer emit. `&amp;` goes last: decoding it
  # first would turn a literal, typed `&amp;lt;` into `<` instead of `&lt;`.
  defp decode_escapes(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace(["&#39;", "&#x27;"], "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
  end

  # The shared core every renderer runs: escape raw HTML, autolink bare URLs,
  # render the Markdown, undo the double-escape, sanitize, and drop images.
  # Every `<img>` the Markdown itself produces is untrusted (a hotlinked remote
  # picture would leak each reader's IP, a foreign attachment is not this
  # author's to show), so `strip_img_tags/1` runs last, after the sanitizer
  # emits its `<img>`. The one legitimate image path — a post's own uploaded
  # attachments — bypasses the pipeline entirely via `render_post/2`'s
  # plain-text markers and is injected afterwards from known-safe parts.
  #
  # `breaks:` (default `true`) decides whether a single newline is a `<br>`.
  # Chat, remote Mastodon text, newsletters and legal address blocks want that
  # (a lone Enter is a deliberate break), so they keep the default. **Posts**
  # pass `breaks: false`: a post body is prose, and Milkdown (the composer)
  # never emits a lone soft-wrap newline — it serializes a real break as a
  # trailing backslash and a paragraph as a blank line. The only bodies with
  # lone newlines are ones hard-wrapped in an external editor or pasted in
  # source mode, where `breaks: true` turned every ~80-column wrap into a
  # visible break (a wall of stray `<br>`s next to long links); `breaks: false`
  # reflows them into flowing paragraphs. The two settings agree on the
  # backslash only because `normalize_hard_breaks/1` respells it first — see
  # there, and don't drop it on the assumption that Earmark reads both.
  defp render_pipeline(text, opts \\ []) do
    # Footnotes bracket the whole pipeline: the syntax becomes plain-text markers
    # before Earmark sees it, and the real markup is built after the scrubber has
    # run (it allows `id` on no tag and `class` only on `<code>`, so the anchors
    # could not survive being emitted any earlier) — see `Footnotes`.
    # A code fence may say more than its language — the file the snippet comes
    # from, the language inside a diff — and Earmark understands exactly one
    # word, so `Fences.normalize/1` folds the info string into one before it
    # ever gets there. See `VutuvWeb.CodeHighlight.Fences`.
    {prepared, footnotes} =
      text
      |> Fences.normalize()
      |> strip_break_artifacts()
      |> normalize_hard_breaks()
      |> Footnotes.prepare()

    prepared
    |> String.replace("<", "&lt;")
    |> autolink_bare_urls()
    |> Earmark.as_html!(breaks: Keyword.get(opts, :breaks, true), pure_links: false)
    # Earmark escapes the ampersand of our pre-escaped `&lt;` — undo the double.
    |> String.replace("&amp;lt;", "&lt;")
    |> HtmlSanitizeEx.markdown_html()
    |> strip_img_tags()
    # Order matters: `CodeHighlight` labels the block and colours its tokens,
    # but leaves a `diff` fence's body alone (it is the one language whose
    # rendering `Diff` owns), so `Diff.render/1` still finds the plain
    # `<pre><code class="language-diff">` inside the labelled wrapper — with the
    # language of the code inside the diff beside it when the fence named one.
    |> CodeHighlight.render()
    |> Diff.render()
    |> scope_table_headers()
    |> Footnotes.inject(footnotes)
  end

  # Name each header cell as a **column** header (WCAG technique H63). A screen
  # reader can guess it for a simple table, and stops guessing on a wide one —
  # which is exactly where it matters: the Arbeitszeugnis review opens with a
  # five-column matrix whose rows are only readable if each cell is announced
  # under the right heading ("Note: 1", not a bare "1").
  #
  # Every `<th>` a pipe table produces is a column header (Earmark emits them
  # only in the `<thead>` row), so the mapping needs no parsing. The sanitizer
  # has already run and allows no `scope` attribute, hence doing it here, on
  # markup this module built.
  defp scope_table_headers(html) do
    String.replace(html, "<th>", ~s(<th scope="col">))
  end

  # The Milkdown editor emits a literal `<br />` for content it has no plain
  # Markdown for: an **empty paragraph** (a blank line the writer adds with
  # Enter, serialized as a standalone `<br />` block) and an **empty table cell**
  # (`| <br /> |`). Since the pipeline escapes `<` a step below (typed HTML must
  # show as literal text), those would otherwise render as literal "<br />" text
  # in the body. Drop every `<br />` tag — an empty paragraph collapses to a
  # normal break, an empty cell stays empty — while leaving **fenced code
  # blocks** verbatim so a real `<br>` in a code sample survives. Real hard
  # breaks serialize as a trailing backslash, not `<br>`, so they are untouched.
  # The editor also normalizes this away at write time
  # (`assets/js/markdown_editor.js`); this is the rendering-side guard for
  # anything already stored or typed in source mode.
  defp strip_break_artifacts(text) do
    # Fast path: almost every body has neither a `<br>` nor a run of 3+ newlines
    # (the editor already normalizes both away at write time), so skip the fence
    # tokenization + regex passes entirely — the same cheap substring guard the
    # `linkify_entities/1` hot path uses one function over.
    if String.contains?(text, ["<br", "\n\n\n"]) do
      ~r/(```[\s\S]*?```|~~~[\s\S]*?~~~)/
      |> Regex.split(text, include_captures: true)
      |> Enum.with_index()
      |> Enum.map_join("", fn
        {chunk, index} when rem(index, 2) == 0 ->
          chunk
          |> String.replace(~r/<br\s*\/?>/i, "")
          |> String.replace(~r/\n{3,}/, "\n\n")

        {fenced_chunk, _index} ->
          fenced_chunk
      end)
    else
      text
    end
  end

  # CommonMark spells a hard break two ways — a trailing backslash and two
  # trailing spaces — and **Earmark reads the backslash only while `breaks:` is
  # off**: `breaks: true` swaps its `<br>` rule for one matching bare whitespace
  # before the newline, which drops the backslash alternative, so the `\` falls
  # through as ordinary text and the newline becomes the break separately. Every
  # hard-broken line of a chat message therefore ended in a visible `\` (reported
  # on a DM thread, 2026-08-17) — and the same for a tagline, an organization
  # description or a job posting, since all four render with the default. The
  # writer never typed that character: it is how Milkdown serializes the break
  # (`assets/js/markdown_editor.js`), which is why `render_post/3` was unaffected
  # and the bug looked like it belonged to messages.
  #
  # So respell it as the two spaces, which **both** settings consume. Doing it
  # here rather than at write time repairs the already-stored bodies too, so this
  # needs none of the repair migrations the other Milkdown round-trip fixes did.
  # `map_outside_code/2` keeps a code fence's line continuations (`curl \`)
  # verbatim, and the lookbehind keeps an escaped backslash (`\\`) at a line end,
  # which is a literal character and not a break.
  defp normalize_hard_breaks(text) do
    if String.contains?(text, "\\"), do: map_outside_code(text, &hard_break_chunk/1), else: text
  end

  defp hard_break_chunk(chunk), do: Regex.replace(~r/(?<!\\)\\(\r?\n)/, chunk, "  \\1")

  @doc """
  Render a feed preview: the Markdown source is cut at a block boundary
  around `:limit` (default #{@preview_limit}) characters — never inside a
  fenced code block — then rendered like `render_post/2`. Returns
  `{safe_html, truncated?}`; pair the flag with a "Read more" link and a
  CSS line-clamp for visual consistency.

  Footnote definitions are taken out before the cut and the ones the surviving
  text still cites are put back after it: they live at the end of a body, so
  cutting them away would strand every reference above as literal `[^1]` source.
  The budget is therefore spent on prose alone, and a note whose paragraph was
  cut goes with it.
  """
  def render_preview(text, images, opts \\ [])

  def render_preview(text, images, opts) when is_binary(text) do
    limit = Keyword.get(opts, :limit, @preview_limit)
    {prose, definitions} = Footnotes.split_definitions(text)
    {snippet, truncated?} = truncate_markdown(prose, limit)
    # `opts` travels on, so a preview marks the author's verified links exactly
    # as the full body does (`render_post/3` ignores the keys meant for us).
    {render_post(Footnotes.reattach(snippet, definitions), images, opts), truncated?}
  end

  def render_preview(_, _images, _opts), do: {Phoenix.HTML.raw(""), false}

  # Bare URLs become `[truncated-display](url)`, but only **outside** code: in a
  # fenced block or an inline code span a URL is sample text, and rewriting
  # `curl https://vutuv.de` into Markdown link syntax corrupted the very snippet
  # the author was showing. The lookbehind skips URLs that are already the
  # target of a Markdown link (`](http…`). A match longer than `@autolink_max`
  # is left as literal text: no genuine URL is that long, and it caps the work
  # per match so a pathological unbroken run can never drive the
  # trailing-punctuation walk (findings F1/F9 — a body of `http://a` plus tens
  # of thousands of `.`/`)` matched as one token).
  defp autolink_bare_urls(text), do: map_outside_code(text, &autolink_chunk/1)

  defp autolink_chunk(chunk) do
    Regex.replace(~r{(?<!\]\()(?<![\w/])(https?://[^\s<>]+)}, chunk, fn _, raw ->
      if byte_size(raw) > @autolink_max do
        raw
      else
        {url, trailing} = split_trailing_punct(raw)
        "[#{truncate_url(url)}](#{url})#{trailing}"
      end
    end)
  end

  @doc """
  Splits a Markdown source into `{:text, chunk}` / `{:code, chunk}` parts, in
  order, so a pass can be applied to the prose while leaving code verbatim.

  Fenced blocks are matched before inline spans, so a line inside ``` is never
  caught by the inline-span alternative. A body with no backtick and no `~~~` is
  one text chunk and skips the split entirely.

  Public for `VutuvWeb.Markdown.Footnotes`, which needs the parts themselves
  (it collects definitions, numbers the references and rewrites in three passes
  over the same split) rather than the single-pass `map_outside_code/2`.
  """
  def split_code_regions(text) do
    if String.contains?(text, ["`", "~~~"]) do
      @code_region
      |> Regex.split(text, include_captures: true)
      |> Enum.with_index()
      |> Enum.map(fn
        {chunk, index} when rem(index, 2) == 0 -> {:text, chunk}
        {code, _index} -> {:code, code}
      end)
    else
      [{:text, text}]
    end
  end

  # Applies `fun` to the parts of a Markdown source that are not code.
  defp map_outside_code(text, fun) do
    text
    |> split_code_regions()
    |> Enum.map_join("", fn
      {:text, chunk} -> fun.(chunk)
      {:code, code} -> code
    end)
  end

  # "…wiki/Elixir_(programming_language)), see!" — sentence punctuation and any
  # `)` beyond the balanced ones belong to the sentence, not the URL. We strip
  # that trailing run in one right-to-left pass instead of recursing a character
  # at a time (each old level re-walked the whole remaining string via
  # `String.last`/`String.slice`/`String.graphemes`, so a long match cost O(n²)
  # time and allocation — findings F1/F9). The paren balance is computed once:
  # a `)` is trailing only while the prefix up to and including it still closes
  # more parens than it opens, so a balanced `(disambiguation)` stays in the
  # href while an unbalanced `)` is dropped — the exact rule the recursion had.
  defp split_trailing_punct(url) do
    graphemes = String.graphemes(url)
    opens = Enum.count(graphemes, &(&1 == "("))
    closes = Enum.count(graphemes, &(&1 == ")"))

    strip =
      graphemes
      |> Enum.reverse()
      |> count_trailing_to_strip(opens, closes)

    {kept, trailing} = Enum.split(graphemes, length(graphemes) - strip)
    {Enum.join(kept), Enum.join(trailing)}
  end

  # How many graphemes to peel off the end, walking the reversed list once. A
  # `.,;:!?…` char always peels; a `)` peels only while the still-kept prefix
  # (`closes` shrinks as each closing paren is peeled; `opens` never does, since
  # a `(` is never trailing) holds an unbalanced close. Stops at the first char
  # that stays, so it never scans past the trailing run.
  defp count_trailing_to_strip(reversed_graphemes, opens, closes) do
    {strip, _closes} =
      Enum.reduce_while(reversed_graphemes, {0, closes}, fn grapheme, {strip, closes} ->
        cond do
          grapheme in @trailing_punct -> {:cont, {strip + 1, closes}}
          grapheme == ")" and closes > opens -> {:cont, {strip + 1, closes - 1}}
          true -> {:halt, {strip, closes}}
        end
      end)

    strip
  end

  # Scheme-less, www-less display text for a bare URL, shortened to the host
  # plus its leading path directory (or more, for the hosts `kept_dirs/1` names)
  # — any deeper path is collapsed into a trailing `…`. So a long
  # "https://www.hostsharing.net/downloads/hostsharing-manual.pdf" reads as
  # "hostsharing.net/downloads/…" instead of a mid-word character cut.
  # `@url_display_max` stays a final safety cap for a pathologically long host
  # or first segment (or a query string on a single-segment path).
  defp truncate_url(url) do
    url
    |> strip_url_scheme()
    |> String.replace_prefix("www.", "")
    |> shorten_url_display()
    |> cap_url_display()
  end

  defp strip_url_scheme(url) do
    url
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
  end

  # host + as many leading path directories as `kept_dirs/1` grants it, eliding
  # anything deeper. A bare host — or one with only a trailing slash or fewer
  # directories than the kept count — keeps its full text; the `…` appears only
  # when there is a further path segment to hide.
  defp shorten_url_display(display) do
    host = display |> String.split("/", parts: 2) |> hd()
    elide_path(display, kept_dirs(host))
  end

  # Hosts whose display keeps more than one leading path directory, because
  # their meaningful unit sits deeper: GitHub is `/:owner/:repo`, and the New
  # York Times dates an article, `/:year/:month/:day/:desk/<headline>`, so one
  # directory leaves a bare "nytimes.com/2026/…" that names nothing while four
  # carry the date and the section. Every other host still collapses after the
  # first directory. The host is matched whole, never by suffix: a subdomain is
  # a different site with its own path shape.
  @dirs_by_host %{"github.com" => 2, "nytimes.com" => 4}

  # This installation's own host keeps TWO (a vutuv profile section is
  # `/:slug/<section>`, so the section — `/tags`, `/work_experiences` — is worth
  # showing). `www.` is stripped from both the display host (in `truncate_url/1`)
  # and the endpoint host so the two forms compare equal, and the own host is
  # derived from the endpoint rather than a literal `vutuv.de`, so it is correct
  # on any third-party installation.
  defp kept_dirs(host) do
    if Fediverse.local_host?(host), do: 2, else: Map.get(@dirs_by_host, host, 1)
  end

  # Keep the host plus up to `keep` leading path directories; a deeper, non-empty
  # segment collapses into a trailing `/…`. A lone trailing slash (or any empty
  # deeper segment) is ignored, so it never adds a spurious `…`.
  defp elide_path(display, keep) do
    [host | rest] = String.split(display, "/")
    {shown, deeper} = Enum.split(rest, keep)
    path = Enum.join([host | Enum.reject(shown, &(&1 == ""))], "/")

    if Enum.any?(deeper, &(&1 != "")), do: path <> "/…", else: path
  end

  defp cap_url_display(display) do
    if String.length(display) > @url_display_max do
      String.slice(display, 0, @url_display_max - 1) <> "…"
    else
      display
    end
  end

  @doc """
  Adds `target="_blank" rel="noopener noreferrer"` to every `<a href` so
  external links open in a new tab without leaking the referrer. Safe to run
  post-sanitization: every remaining `<a>` came out of the scrubber. Shared with
  `VutuvWeb.EmailMarkdown`.

  A **same-page** `href="#…"` is left alone: sending a reader to a second tab to
  reach an anchor on the page they are already looking at is never what they
  meant. That is what the footnote reference and its back-link are
  (`VutuvWeb.Markdown.Footnotes`), and it was already the right answer for a
  hand-typed `[x](#y)`.
  """
  def open_links_in_new_tab(html) do
    String.replace(
      html,
      ~r/<a href="(?!#)/,
      ~s(<a target="_blank" rel="noopener noreferrer" href=")
    )
  end

  @doc """
  Appends `query` to a URL that may already have one, or hands it back unchanged
  for a `nil` query.

  Its reason to exist is the one URL in this application that arrives with a
  query already on it: a cropped picture carries the cache-buster
  `?v=<hash>` (`Vutuv.Posts.PostImage.url/2`), and a capability appended by
  overwriting rather than joining would drop the buster and serve a year-cached
  copy of the old frame. Shared with `Vutuv.MastodonApi.Presenter`, which puts
  the same capability on the attachment URLs beside the body's.
  """
  def append_query(url, nil), do: url

  def append_query(url, query),
    do: url |> URI.parse() |> URI.append_query(query) |> to_string()

  @doc """
  Rewrites root-relative `/path` URLs in rendered HTML to absolute `base/path`,
  for a standalone context (an RSS/JSON feed, a downloaded CV, a federated
  note). The negative lookahead leaves a protocol-relative `//host` URL alone:
  it already resolves, and prefixing it would corrupt it into `base//host`.
  `attrs` picks which URL attributes to rewrite (both `src` and `href` by
  default; the CV passes just `["href"]`). Shared by VutuvWeb.Feeds,
  VutuvWeb.Fediverse.Docs, VutuvWeb.CV.Html and the Mastodon adapter so the
  tricky guard lives once.

  A trailing slash on `base` is trimmed here rather than at each call site: this
  appends its own, and `https://host//path` is a **protocol-relative** URL
  naming a host called `path` — every picture in the document would quietly
  point at somebody else's server. Callers spell the base three different ways,
  so only one of them can guard it, and that is this one.
  """
  def absolutize_html(html, base, attrs \\ ["src", "href"]) do
    String.replace(html, pattern(attrs), "\\1=\"#{String.trim_trailing(base, "/")}/")
  end

  # The sigil interpolates `attrs`, so writing it inline was a `Regex.compile`
  # on **every call** — one PCRE compile per status in a Mastodon timeline (up
  # to 40 a request) and per item in an RSS feed, for an argument that has
  # exactly two values in the whole repo. Both are compiled once here; anything
  # else still works and pays the old price.
  @src_href ~r{(src|href)="/(?!/)}
  @href_only ~r{(href)="/(?!/)}

  defp pattern(["src", "href"]), do: @src_href
  defp pattern(["href"]), do: @href_only
  defp pattern(attrs), do: ~r{(#{Enum.join(attrs, "|")})="/(?!/)}

  # No capture group, so the split interleaves whole `<pre>` blocks between the
  # segments around them and nothing else.
  @preformatted ~r{<pre\b[^>]*>.*?</pre>}s

  @block_tags "p|div|ul|ol|li|blockquote|h[1-6]|table|thead|tbody|tfoot|tr|td|th|br|hr|figure|figcaption|dl|dt|dd|pre|section|article"
  @block_tag "(?:<(?:#{@block_tags})\\b[^>]*>|</(?:#{@block_tags})>)"

  @soft_newline ~r/[ \t]*\r?\n[ \t]*/
  @after_block ~r{(#{@block_tag})\s+}
  @before_block ~r{\s+(#{@block_tag})}

  @doc """
  Strips the layout whitespace out of rendered HTML, for a reader that renders
  it as **preformatted text**.

  Earmark lays its output out to be read in a source file: a newline after every
  opening `<p>`, indented list items, trailing spaces before a closing tag. A
  browser collapses all of it, which is why the page is right and why this pass
  changes nothing on any surface of ours. Mastodon's `.status__content p`
  carries `white-space: pre-wrap`, so it **draws** every one of those newlines:
  each paragraph opens with a blank line and each `<li>`'s text lands on the
  line below its own bullet. The Mastodon client API renders the same way, so
  both wire surfaces run this.

  What is left is the whitespace a browser would show too: a soft newline inside
  a paragraph becomes the single space it renders as (posts are rendered with
  `breaks: false`, so those two source lines are one flowing line on our page
  as well, and a hard break is a `<br>` long before this), while the whitespace
  around a block tag goes. Content inside `<pre>` is the author's own and is
  handed through untouched, since Mastodon renders `pre` preformatted on purpose.
  """
  def compact_html(html) when is_binary(html) do
    @preformatted
    |> Regex.split(html, include_captures: true)
    |> Enum.map_join(&compact_segment/1)
  end

  defp compact_segment("<pre" <> _ = preformatted), do: preformatted

  defp compact_segment(text) do
    text
    |> String.replace(@soft_newline, " ")
    |> String.replace(@after_block, "\\1")
    |> String.replace(@before_block, "\\1")
  end

  ## @handle / fediverse mentions and #hashtags

  # Turns every `@handle` of an existing member into a same-tab link to their
  # profile (name in a `title` hover tooltip), every fully-qualified
  # `@user@host` fediverse handle into a **new-tab** link to that remote
  # account, and every `#hashtag` of a non-empty tag into a link to its
  # `/tags/:slug` page. Runs on the already-rendered, sanitized HTML (after
  # `open_links_in_new_tab/1`, so the internal member/tag links stay same-tab
  # while the fediverse link sets its own `target="_blank"`), and only on text
  # that is **not** inside a `code`/`pre`/`a` element — an entity typed in code
  # is sample text and we never nest a link in a link.
  #
  # Each body resolves its handles and its hashtags in **one** DB query each;
  # a body with no `@`/`#` at all does no work (so the pure, DB-free unit tests
  # in `markdown_test.exs` keep working without a sandbox).
  defp linkify_entities(html, mode \\ :all, form \\ :local) do
    # Cheap bail-out for the common case: no `@`/`#` means no entity to link,
    # so the feed hot path skips tokenizing and scanning entirely.
    if String.contains?(html, "@") or String.contains?(html, "#") do
      linkify_present_entities(html, mode, form)
    else
      html
    end
  end

  defp linkify_present_entities(html, mode, form) do
    tokens = tokenize_html(html)

    case entity_candidates(tokens) do
      {[], [], [], false} ->
        html

      {mentions, local_mentions, hashtags, _fediverse?} ->
        # `:hashtags_only` drops the **bare** handles — in remote content a
        # `@name` names an account over there, not the vutuv member who happens
        # to share the handle. A fully-qualified address on our own host has no
        # such ambiguity (the host names us), so it is resolved in both modes,
        # which is why the two forms read from two maps rather than one: sharing
        # a map would have the address lookup quietly link the bare handles too.
        # With nothing to look up either form falls through as plain text. A
        # body carrying only foreign addresses still reaches here (they need no
        # lookup) and gets linked.
        handles = if mode == :all, do: mentions ++ local_mentions, else: local_mentions
        targets = if handles == [], do: %{}, else: mention_targets(handles)
        bare_users = if mode == :all, do: targets, else: %{}
        tags = Tags.linkable_slugs(hashtags)

        tokens
        |> map_linkable_text(&link_entities_in_text(&1, bare_users, targets, tags, form))
        |> IO.iodata_to_binary()
    end
  end

  # Splits HTML into alternating text / tag tokens (tags kept as their own
  # tokens), so a tag-depth walk can tell text apart from markup.
  defp tokenize_html(html), do: Regex.split(~r/<[^>]+>/, html, include_captures: true)

  # The unique, lowercased {handles, own-host handles, hashtags} sitting in
  # linkable text.
  defp entity_candidates(tokens) do
    {mentions, local_mentions, hashtags, fediverse?} =
      reduce_linkable_text(tokens, {[], [], [], false}, fn text, acc ->
        @entity
        |> Regex.scan(text, capture: :all_but_first)
        |> Enum.reduce(acc, &collect_candidate/2)
      end)

    {Enum.uniq(mentions), Enum.uniq(local_mentions), Enum.uniq(hashtags), fediverse?}
  end

  # `Regex.scan` truncates trailing unmatched groups, so each hit arrives at a
  # different length: a fediverse handle as `["user", "host"]`, a mention as
  # `["", "", "handle"]`, a hashtag as `["", "", "", "hashtag"]`. Dispatch on
  # which group is set. An address on somebody else's host needs no DB lookup,
  # so it only raises the `fediverse?` flag — that keeps the token walk from
  # being skipped for a body whose only entities are foreign addresses.
  #
  # Two of our own hosts wear that same shape and neither leaves the site. Our
  # **tag host** (issue #1330): `@php@tags.<host>` is a topic of this
  # installation, so its user part is a tag slug and joins the hashtags —
  # resolved by the same single `Tags.linkable_slugs/1` call, alias redirects
  # included. Our **main host** (issue #1560): `@ada@<host>` is a member or a
  # page of ours, so its user part is a handle and gets looked up like a bare
  # `@ada` — kept in its own list because it resolves even in `:hashtags_only`
  # mode, where a bare handle deliberately does not.
  defp collect_candidate([user, host | _], {mentions, local, hashtags, _fediverse?})
       when user != "" and host != "" do
    cond do
      Fediverse.tag_host?(host) -> {mentions, local, [String.downcase(user) | hashtags], true}
      Fediverse.local_host?(host) -> {mentions, [String.downcase(user) | local], hashtags, true}
      true -> {mentions, local, hashtags, true}
    end
  end

  defp collect_candidate([_, _, handle | _], {mentions, local, hashtags, fediverse?})
       when handle != "",
       do: {[String.downcase(handle) | mentions], local, hashtags, fediverse?}

  defp collect_candidate([_, _, _, hashtag], {mentions, local, hashtags, fediverse?}),
    do: {mentions, local, [String.downcase(hashtag) | hashtags], fediverse?}

  # Walks the token stream, applying `fun` to every text token outside a
  # skip element and leaving tags and skipped text untouched.
  defp map_linkable_text(tokens, fun) do
    {mapped, _depth} =
      Enum.map_reduce(tokens, 0, fn token, depth ->
        cond do
          tag_token?(token) -> {token, entity_skip_depth(depth, token)}
          depth > 0 -> {token, depth}
          true -> {fun.(token), depth}
        end
      end)

    mapped
  end

  # Folds `fun` over every text token outside a skip element.
  defp reduce_linkable_text(tokens, acc, fun) do
    {acc, _depth} =
      Enum.reduce(tokens, {acc, 0}, fn token, {acc, depth} ->
        cond do
          tag_token?(token) -> {acc, entity_skip_depth(depth, token)}
          depth > 0 -> {acc, depth}
          true -> {fun.(token, acc), depth}
        end
      end)

    acc
  end

  defp tag_token?(token), do: String.starts_with?(token, "<")

  # Tracks how deeply nested we are inside skip elements (a/code/pre).
  defp entity_skip_depth(depth, tag) do
    case Regex.run(~r{^<\s*(/?)\s*([a-zA-Z0-9]+)}, tag) do
      [_, "/", name] -> if skip_tag?(name), do: max(depth - 1, 0), else: depth
      [_, "", name] -> if skip_tag?(name), do: depth + 1, else: depth
      _ -> depth
    end
  end

  defp skip_tag?(name), do: String.downcase(name) in @entity_skip_tags

  defp link_entities_in_text(text, bare_users, address_users, tags, form) do
    Regex.replace(@entity, text, fn
      whole, user, host, "", "" -> fediverse_link(whole, user, host, address_users, tags, form)
      whole, "", "", handle, "" -> mention_link(whole, handle, bare_users, form)
      whole, "", "", "", hashtag -> hashtag_link(whole, hashtag, tags)
    end)
  end

  # A fully-qualified `@user@host` address. Almost always somebody else's
  # account — but two of our own hosts wear the same shape, and for both the
  # reader wants a page here rather than a trip to another server: our tag host
  # names a topic, and our main host names a member or a page of ours.
  defp fediverse_link(whole, user, host, users, tags, form) do
    cond do
      Fediverse.tag_host?(host) -> tag_actor_link(whole, user, tags)
      Fediverse.local_host?(host) -> local_address_link(whole, user, host, users, form)
      true -> remote_actor_link(user, host)
    end
  end

  # `@ada@vutuv.de` is the member `@ada`, spelled the way a remote server writes
  # a mention of one of us — so it links to the profile in the same tab, exactly
  # like the bare `@ada` (issue #1560). Sending the reader to
  # `https://vutuv.de/@ada` was the Mastodon-web convention applied to a host
  # that is not Mastodon: that path is not a page vutuv serves, so the one
  # clickable thing in a sentence naming a member 404ed on our own domain.
  #
  # On the site the address is **shortened to the handle**: the reader is
  # already on the host it names, so `@ada@vutuv.de` and `@ada` are the same
  # person written long and short, and the long one only pushes the sentence
  # around. The stored body keeps whatever was typed — a post arriving from
  # another server names us in full, and this is what makes it read like one of
  # ours. `mention_form: :address` (the outgoing Note) keeps it whole instead,
  # because over there the short form names somebody else. An unresolved handle
  # stays plain text, like a bare mention, and is shortened the same way: a
  # handle nobody holds reads no better for being spelled out.
  defp local_address_link(whole, user, host, users, form) do
    case {Map.get(users, String.downcase(user)), form} do
      {nil, :local} -> "@" <> user
      {nil, :address} -> whole
      {target, :local} -> mention_anchor(target, user)
      {target, :address} -> mention_anchor(target, "#{user}@#{host}")
    end
  end

  # A topic's Fediverse address (issue #1330) is `@<slug>@tags.<our host>`, so a
  # member who writes one is naming a tag of **this** installation. Sending the
  # reader to the Mastodon-web convention `https://tags.<host>/@<slug>` was
  # doubly wrong: that host serves the actor's ActivityPub JSON at `/<slug>` and
  # nothing a person can read, and `@<slug>` is not even a legal tag slug there,
  # so the one clickable thing in a sentence about a vutuv topic left vutuv and
  # 404ed. It links to `/tags/:slug` instead — same tab, no `rel`, exactly like
  # the `#hashtag` that means the same thing.
  #
  # The **address stays the visible text**: the author wrote it so a reader on
  # another network can copy it, and rewriting it to `#slug` would take that
  # away. Gated on the same non-empty-tag rule as `hashtag_link/3` (an
  # unresolved slug stays plain text), and `Tags.linkable_slugs/1` hands back
  # the canonical slug, so an alias lands on the page rather than a redirect.
  defp tag_actor_link(whole, user, tags) do
    case Map.get(tags, String.downcase(user)) do
      nil -> whole
      slug -> ~s(<a href="/tags/#{slug}" class="hashtag">#{whole}</a>)
    end
  end

  # Any other host: link to that remote account's profile at the Mastodon-web
  # convention `https://host/@user` (geno.social and the vast majority of
  # servers). This is a pure string mapping — no WebFinger lookup — so it also
  # works on air-gapped installs and never leaks a reader's request to the
  # remote host at render time. The host is lowercased (hostnames are
  # case-insensitive); the typed user case is kept in both the URL and the
  # label. Opens in a new tab like other external links; both parts are a
  # validated charset (`[A-Za-z0-9_]` / `[A-Za-z0-9.-]`), so no escaping needed.
  defp remote_actor_link(user, host) do
    href = "https://#{String.downcase(host)}/@#{user}"

    ~s(<a href="#{href}" target="_blank" rel="noopener noreferrer" class="mention">@#{user}@#{host}</a>)
  end

  # A bare `@ada` is the everyday spelling here and the wrong one everywhere
  # else: on the server this post is federated to, `@ada` names *their* member
  # of that name. So `mention_form: :address` writes it out as `@ada@vutuv.de`,
  # which is the same account under a name that means the same thing on every
  # server. Only a handle that resolves is expanded — a stray `@word` is not an
  # account here, and inventing an address for it would name one.
  defp mention_link(whole, handle, users, form) do
    case Map.get(users, String.downcase(handle)) do
      nil -> whole
      target -> mention_anchor(target, mention_label(handle, form))
    end
  end

  defp mention_label(handle, :local), do: handle
  defp mention_label(handle, :address), do: handle <> "@" <> VutuvWeb.Endpoint.host()

  # Who a handle names, in two batched queries per rendered body — never one per
  # mention. The resolution itself lives in `Vutuv.Mentions` (which is also
  # where the namespace merge and the page-visibility gate are explained): it
  # moved there when the composer's `@`-picker became a second caller (issue
  # #1748), because a visibility answer that lives at its call site is a
  # visibility answer that drifts, and this drift would have been a chip
  # promising a link this renderer refuses to write.
  defp mention_targets(handles), do: Mentions.resolvable_handles(handles)

  # The written hashtag keeps its casing in the text; the href is the slug
  # `Tags.linkable_slugs/1` hands back, which is the canonical one when the
  # author wrote an alternative name for a topic (issue #1338) — so the reader
  # lands on the page rather than on a redirect to it.
  defp hashtag_link(whole, hashtag, tags) do
    case Map.get(tags, String.downcase(hashtag)) do
      nil -> whole
      slug -> hashtag_anchor(slug, hashtag)
    end
  end

  # The display text is the handle the author typed (case preserved); the href
  # is the canonical lowercase slug; the title is the member's full name (or the
  # handle itself for a nameless member).
  defp mention_anchor(%Organization{} = organization, typed_handle) do
    ~s(<a href="#{Organizations.canonical_path(organization)}" ) <>
      ~s(title="#{escape(organization.name)}" class="mention">@#{typed_handle}</a>)
  end

  defp mention_anchor(user, typed_handle) do
    name =
      case UserHelpers.full_name(user) do
        "" -> "@" <> user.username
        full -> full
      end

    ~s(<a href="/#{user.username}" title="#{escape(name)}" class="mention">@#{typed_handle}</a>)
  end

  # The display text is the hashtag the author typed (case preserved); the href
  # is the canonical lowercase tag slug. Only non-empty tags reach here, so the
  # link never lands on a tag page with nothing on it. Both parts are from a
  # validated charset (`[a-z0-9-]` slug, `[A-Za-z0-9_]` typed), so no escaping.
  defp hashtag_anchor(slug, typed_hashtag) do
    ~s(<a href="/tags/#{slug}" class="hashtag">##{typed_hashtag}</a>)
  end

  defp escape(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  @doc """
  A per-render hex nonce for collision-proof plain-text markers (the inline
  post-image markers here, the footnote markers in `VutuvWeb.Markdown.Footnotes`):
  an author cannot type a literal marker that collides with a generated one.
  """
  def marker_nonce, do: Base.encode16(:crypto.strong_rand_bytes(6))

  ## Inline post images

  # Swaps every allowed `![alt](url)` for a plain-text marker and returns the
  # replacement <img> HTML per marker. The marker carries a per-render nonce,
  # so an author cannot type a literal marker that collides with a real one.
  defp extract_inline_images(text, images, image_query) do
    allowed = allowed_srcs(images)
    nonce = marker_nonce()

    @inline_image
    |> Regex.scan(text)
    |> Enum.reduce({text, []}, fn [full, alt, src], {text, replacements} ->
      {base, alignment} = split_alignment(src)
      # A crop cache-buster (`?v=<hash>`) is not identity: a body stored under
      # an earlier crop must keep resolving to the image, at its current URL.
      base = String.replace(base, ~r/\?v=[A-Za-z0-9_-]+\z/, "")

      case Map.get(allowed, base) do
        nil ->
          {text, replacements}

        {image, canonical_src} ->
          marker = "VUTUVIMG#{nonce}N#{length(replacements)}END"
          src = append_query(canonical_src, image_query && image_query.(image))

          {String.replace(text, full, marker, global: false),
           [{marker, inline_img_html(src, alt, image, alignment)} | replacements]}
      end
    end)
  end

  # An src may carry one `#fragment`; only the known alignment words map to a
  # modifier class, anything else (or nothing) renders full width. The base
  # URL — fragment stripped either way — is what gets whitelisted and served.
  defp split_alignment(src) do
    case String.split(src, "#", parts: 2) do
      [base, fragment] -> {base, if(fragment in @image_alignments, do: fragment)}
      [base] -> {base, nil}
    end
  end

  # Every URL form an old or new body may carry (`PostImage.url_forms/2`,
  # incl. the pre-AVIF `.webp` form) maps to the image and its **canonical**
  # URL — the rendered <img> always points at the current format.
  defp allowed_srcs(images) do
    for image <- images,
        version <- PostImage.versions(),
        src <- PostImage.url_forms(image, version),
        into: %{} do
      {src, {image, PostImage.url(image, version)}}
    end
  end

  defp inline_img_html(src, md_alt, image, alignment) do
    alt = if md_alt == "", do: image.alt || "", else: md_alt

    dimensions =
      if image.width && image.height do
        ~s( width="#{image.width}" height="#{image.height}")
      else
        ""
      end

    class =
      if alignment do
        "post-inline-image post-inline-image--#{alignment}"
      else
        "post-inline-image"
      end

    ~s(<img src="#{escape(src)}" alt="#{escape(alt)}"#{dimensions} loading="lazy" class="#{class}">)
  end

  @doc """
  Strips every `<img>` from HTML. Every `<img>` the pipeline produced is
  untrusted (remote hotlinks, foreign attachments); only the marker-injected
  ones below may survive. Shared with `VutuvWeb.EmailMarkdown`.
  """
  def strip_img_tags(html) do
    String.replace(html, ~r/<img\b[^>]*>/i, "")
  end

  defp inject_inline_images(html, replacements) do
    Enum.reduce(replacements, html, fn {marker, img_html}, html ->
      String.replace(html, marker, img_html)
    end)
  end

  ## Preview truncation

  # Cuts Markdown source at a block boundary near `limit` chars. Blocks are
  # blank-line separated, except inside fenced code blocks (``` / ~~~), which
  # stay atomic — cutting a fence in half breaks the rendering of everything
  # after it. A single overlong non-fence first block is word-cut instead.
  defp truncate_markdown(text, limit) do
    if String.length(text) <= limit do
      {text, false}
    else
      [first | rest] = split_blocks(text)

      first =
        if String.length(first) > limit and not fence_block?(first) do
          word_cut(first, limit)
        else
          first
        end

      {accumulate_blocks(rest, [first], String.length(first), limit), true}
    end
  end

  defp accumulate_blocks([], kept, _length, _limit), do: join_blocks(kept)

  defp accumulate_blocks([block | rest], kept, length, limit) do
    new_length = length + 2 + String.length(block)
    remaining = limit - length - 2

    cond do
      new_length <= limit ->
        accumulate_blocks(rest, [block | kept], new_length, limit)

      # Near-full already: stop. There is plenty above for the CSS clamp.
      remaining < @preview_min_block ->
        join_blocks(kept)

      # The next whole block overflows but there is room. Don't drop it — that is
      # what left a one-line intro stranded above a long list. A fence is atomic
      # (cutting it breaks rendering everything after), so include it whole and
      # let the CSS line-clamp trim it; any other block is word-cut to the budget.
      fence_block?(block) ->
        join_blocks([block | kept])

      true ->
        join_blocks([word_cut(block, remaining) | kept])
    end
  end

  defp join_blocks(kept), do: kept |> Enum.reverse() |> Enum.join("\n\n")

  # Splits into blank-line separated blocks, treating fenced code as atomic:
  # a blank line inside an open fence does not end the block.
  defp split_blocks(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({[], [], false}, &collect_block_line/2)
    |> then(fn {blocks, current, _in_fence} ->
      blocks = if current == [], do: blocks, else: [Enum.reverse(current) | blocks]

      blocks
      |> Enum.reverse()
      |> Enum.map(&Enum.join(&1, "\n"))
    end)
  end

  defp collect_block_line(line, {blocks, current, in_fence}) do
    in_fence = if fence_delimiter?(line), do: not in_fence, else: in_fence

    cond do
      String.trim(line) != "" or in_fence -> {blocks, [line | current], in_fence}
      current == [] -> {blocks, [], in_fence}
      true -> {[Enum.reverse(current) | blocks], [], in_fence}
    end
  end

  defp fence_delimiter?(line), do: Regex.match?(~r/^\s*(```|~~~)/, line)

  defp fence_block?(block) do
    block |> String.trim_leading() |> String.starts_with?(["```", "~~~"])
  end

  defp word_cut(text, limit) do
    cut =
      text
      |> String.slice(0, limit)
      # Drop the (likely cut-through) last word so the cut lands on a boundary.
      |> String.replace(~r/\S*\z/, "")
      |> String.trim_trailing()

    cut <> " …"
  end
end
