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

  alias Vutuv.Accounts
  alias Vutuv.Fediverse
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
  # tried **first**, so `@a@b.social` links to the remote account, not the local
  # member `@a`; handles/tags match permissively and are validated against the
  # DB by `linkify_entities/1`. Captures: 1 = fediverse user, 2 = fediverse
  # host, 3 = local handle, 4 = hashtag (exactly one kind is set per hit).
  @entity Vutuv.Mentions.entity_regex()

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
  """
  def render_post(text, images, opts \\ [])

  def render_post(text, images, opts) when is_binary(text) and is_list(images) do
    {prepared, replacements} = extract_inline_images(text, images)

    prepared
    |> render_pipeline(breaks: false)
    |> open_links_in_new_tab()
    |> mark_verified_author_links(Keyword.get(opts, :verified_links, []))
    |> linkify_entities()
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
      account (it unambiguously names one), the same as in a member post;
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
  `/tags/:slug` — so they are left alone: nofollowing our own tag pages would
  throw away the internal linking they exist for.
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

  The grammar is deliberately wider than the `@entity` regex's ASCII
  `[A-Za-z0-9_]`: `#München` is an ordinary German hashtag and a line holding
  one must split like any other. Whether a pill then *links* is a separate
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

  # A `#` followed by at least one word character, the Unicode reading of
  # "word" (see `split_trailing_hashtags/1`). Punctuation is not part of a
  # hashtag, so a line like "Mehr dazu: #Berlin." keeps its full stop and is
  # therefore not a hashtag line — which is right, it is a sentence.
  @hashtag_token ~r/^#([\p{L}\p{N}_]+)$/u

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

  Entities are **not** linkified, so this costs no DB query.
  """
  def to_plain_text(text) when is_binary(text) do
    text |> render_pipeline() |> html_to_plain_text()
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
  # trailing backslash and a paragraph as a blank line, both of which render the
  # same either way. The only bodies with lone newlines are ones hard-wrapped in
  # an external editor or pasted in source mode, where `breaks: true` turned
  # every ~80-column wrap into a visible break (a wall of stray `<br>`s next to
  # long links); `breaks: false` reflows them into flowing paragraphs.
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
      text |> Fences.normalize() |> strip_break_artifacts() |> Footnotes.prepare()

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
  # plus its leading path directory (or **two** directories for the hosts in
  # `keep_two_dirs?/1`) — any deeper path is collapsed into a trailing `…`. So a
  # long "https://www.hostsharing.net/downloads/hostsharing-manual.pdf" reads as
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

  # host + its leading path directory (two for `keep_two_dirs?/1` hosts),
  # eliding anything deeper. A bare host — or one with only a trailing slash or
  # fewer directories than the kept count — keeps its full text; the `…` appears
  # only when there is a further path segment to hide.
  defp shorten_url_display(display) do
    host = display |> String.split("/", parts: 2) |> hd()
    elide_path(display, if(keep_two_dirs?(host), do: 2, else: 1))
  end

  # Hosts whose display keeps TWO leading path directories, because their
  # meaningful unit is two segments deep: GitHub (`/:owner/:repo`) and this
  # installation's own host (a vutuv profile section is `/:slug/<section>`, so
  # the section — `/tags`, `/work_experiences` — is worth showing). Every other
  # host still collapses after the first directory. `www.` is stripped from both
  # the display host (in `truncate_url/1`) and the endpoint host so the two
  # forms compare equal, and the own host is derived from the endpoint rather
  # than a literal `vutuv.de`, so it is correct on any third-party installation.
  @two_dir_hosts ~w(github.com)

  defp keep_two_dirs?(host) do
    host in @two_dir_hosts or Fediverse.local_host?(host)
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
  Rewrites root-relative `/path` URLs in rendered HTML to absolute `base/path`,
  for a standalone context (an RSS/JSON feed, a downloaded CV, a federated
  note). The negative lookahead leaves a protocol-relative `//host` URL alone:
  it already resolves, and prefixing it would corrupt it into `base//host`.
  `attrs` picks which URL attributes to rewrite (both `src` and `href` by
  default; the CV passes just `["href"]`). Shared by VutuvWeb.Feeds,
  VutuvWeb.Fediverse.Docs and VutuvWeb.CV.Html so the tricky guard lives once.
  """
  def absolutize_html(html, base, attrs \\ ["src", "href"]) do
    String.replace(html, ~r{(#{Enum.join(attrs, "|")})="/(?!/)}, "\\1=\"#{base}/")
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
  defp linkify_entities(html, mode \\ :all) do
    # Cheap bail-out for the common case: no `@`/`#` means no entity to link,
    # so the feed hot path skips tokenizing and scanning entirely.
    if String.contains?(html, "@") or String.contains?(html, "#") do
      linkify_present_entities(html, mode)
    else
      html
    end
  end

  defp linkify_present_entities(html, mode) do
    tokens = tokenize_html(html)

    case entity_candidates(tokens) do
      {[], [], false} ->
        html

      {mentions, hashtags, _fediverse?} ->
        # With an empty user map every mention falls through as plain text
        # (`mention_link/3`), which is exactly what :hashtags_only wants. A body
        # carrying only fediverse handles still reaches here (they need no
        # lookup, so both `mentions` and `hashtags` stay empty) and gets linked.
        users =
          if mode == :all, do: mention_targets(mentions), else: %{}

        tags = Tags.linkable_slugs(hashtags)

        tokens
        |> map_linkable_text(&link_entities_in_text(&1, users, tags))
        |> IO.iodata_to_binary()
    end
  end

  # Splits HTML into alternating text / tag tokens (tags kept as their own
  # tokens), so a tag-depth walk can tell text apart from markup.
  defp tokenize_html(html), do: Regex.split(~r/<[^>]+>/, html, include_captures: true)

  # The unique, lowercased {handles, hashtags} sitting in linkable text.
  defp entity_candidates(tokens) do
    {mentions, hashtags, fediverse?} =
      reduce_linkable_text(tokens, {[], [], false}, fn text, acc ->
        @entity
        |> Regex.scan(text, capture: :all_but_first)
        |> Enum.reduce(acc, &collect_candidate/2)
      end)

    {Enum.uniq(mentions), Enum.uniq(hashtags), fediverse?}
  end

  # `Regex.scan` truncates trailing unmatched groups, so each hit arrives at a
  # different length: a fediverse handle as `["user", "host"]`, a mention as
  # `["", "", "handle"]`, a hashtag as `["", "", "", "hashtag"]`. Dispatch on
  # which group is set. A fediverse handle needs no DB lookup, so it only raises
  # the `fediverse?` flag — that keeps the token walk from being skipped for a
  # body whose only entities are fediverse handles.
  #
  # The one exception is our **own tag host** (issue #1330): `@php@tags.<host>`
  # is a topic of this installation wearing a Fediverse address, so its user
  # part is a tag slug and joins the hashtags — resolved by the same single
  # `Tags.linkable_slugs/1` call, alias redirects included.
  defp collect_candidate([user, host | _], {mentions, hashtags, _fediverse?})
       when user != "" and host != "" do
    if Fediverse.tag_host?(host),
      do: {mentions, [String.downcase(user) | hashtags], true},
      else: {mentions, hashtags, true}
  end

  defp collect_candidate([_, _, handle | _], {mentions, hashtags, fediverse?})
       when handle != "",
       do: {[String.downcase(handle) | mentions], hashtags, fediverse?}

  defp collect_candidate([_, _, _, hashtag], {mentions, hashtags, fediverse?}),
    do: {mentions, [String.downcase(hashtag) | hashtags], fediverse?}

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

  defp link_entities_in_text(text, users, tags) do
    Regex.replace(@entity, text, fn
      whole, user, host, "", "" -> fediverse_link(whole, user, host, tags)
      whole, "", "", handle, "" -> mention_link(whole, handle, users)
      whole, "", "", "", hashtag -> hashtag_link(whole, hashtag, tags)
    end)
  end

  # A fully-qualified `@user@host` address. Almost always somebody else's
  # account — but our **own tag host** wears the same shape, and there the
  # reader wants the tag page here rather than a trip to another server.
  defp fediverse_link(whole, user, host, tags) do
    if Fediverse.tag_host?(host),
      do: tag_actor_link(whole, user, tags),
      else: remote_actor_link(user, host)
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

  defp mention_link(whole, handle, users) do
    case Map.get(users, String.downcase(handle)) do
      nil -> whole
      target -> mention_anchor(target, handle)
    end
  end

  # Members and organizations share one handle namespace (the `handles`
  # registry, issue #941), so a handle belongs to at most one of them and the
  # two maps cannot disagree. Merging members **over** organizations anyway is
  # the safe direction if that invariant were ever broken: a person's profile
  # is the more sensitive destination to get right.
  #
  # Two batched queries per rendered body, never one per mention.
  defp mention_targets(handles) do
    handles
    |> Organizations.get_organizations_by_usernames()
    |> Map.merge(Accounts.get_users_by_usernames(handles))
  end

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
  defp extract_inline_images(text, images) do
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

          {String.replace(text, full, marker, global: false),
           [{marker, inline_img_html(canonical_src, alt, image, alignment)} | replacements]}
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
