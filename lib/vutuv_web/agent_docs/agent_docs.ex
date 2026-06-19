defmodule VutuvWeb.AgentDocs do
  @moduledoc """
  Agent-readable sibling formats of the public pages — **the one chokepoint
  for every non-HTML page representation.**

  Every public page that supports it is also available as Markdown, plain
  text (80 columns), JSON and XML under the same URL plus an extension, and
  the profile additionally as a vCard:

      /stefan.wintermeyer        the HTML page
      /stefan.wintermeyer.md     Markdown (also via `Accept: text/markdown`)
      /stefan.wintermeyer.txt    plain text (also via `Accept: text/plain`)
      /stefan.wintermeyer.json   JSON (also via `Accept: application/json`)
      /stefan.wintermeyer.xml    XML (also via `Accept: application/xml`)
      /stefan.wintermeyer.vcf    vCard (also via `Accept: text/vcard`)

  The extension is parsed by `VutuvWeb.Plug.AgentFormat` (endpoint); the
  `Accept` negotiation happens here, Cloudflare's "markdown for agents"
  style. Every variant renders the **anonymous public view** — never
  session-dependent data — so the responses stay cache-safe.

  ## How a page supports the formats

  The controller action calls `respond/2`, which owns the standard branch —
  HTML (with `put_html_alternates/2` for the `<link rel="alternate">` head
  tags and the `Vary: Accept` header) or the agent doc:

      AgentDocs.respond(conn,
        html: fn conn -> render(conn, "index.html", ...) end,
        doc: fn -> SomeDoc.build(...) end
      )

  Actions with more intricate flows (the post permalink's redirect/teaser
  cascade, the viewer-dependent email show) branch on `negotiate/2`
  themselves and must remember `put_html_alternates/2` on the HTML arm.

  A *doc* is one plain map per page (built by the `VutuvWeb.AgentDocs.*Doc`
  modules) that all formats render from — **that map is the single source of
  truth**. If you change what a public HTML page shows, change the page's
  doc module too; `test/vutuv_web/agent_docs/agent_docs_drift_test.exs`
  fails when the HTML page and the agent documents drift apart.

  ## Versioning and headers

  Docs carry `schema_version` (bumped only on breaking changes; additions
  are free) and `generated_at`. Responses carry `Content-Signal` rendered
  from the page's two opt-out axes — `noindex` (the member's search-engine
  choice, or a page-level restriction) and `noai` (the member's AI choice)
  — plus `Vary: Accept`, and for Markdown an `x-markdown-tokens` estimate.

  Markdown and text docs end with one `Accept-Language`-dependent extra: a
  pointer to the same page in the reader's language when a translation
  exists (declared via `Vary: accept-language`). The doc content itself
  stays locale-stable — English unless `?lang=` says otherwise.
  """

  use Gettext, backend: VutuvWeb.Gettext

  import Plug.Conn

  alias VutuvWeb.AgentDocs.JSON
  alias VutuvWeb.AgentDocs.Markdown
  alias VutuvWeb.AgentDocs.Text
  alias VutuvWeb.AgentDocs.VCard
  alias VutuvWeb.AgentDocs.Xml

  # v2 (2026-06): email entries gained a `type` and changed shape from a bare
  # address string to a `{id, type, value}` map, matching phone_numbers.
  # v3 (2026-06): a member's handle is now `username` (was `slug`); post replies'
  # `author_slug` likewise became `author_username`. The DB column + the whole
  # codebase moved from `active_slug` to `username` to match what humans call it.
  @schema_version 3

  @content_types %{
    md: "text/markdown",
    txt: "text/plain",
    json: "application/json",
    xml: "application/xml",
    vcf: "text/vcard"
  }

  # The one list of formats the system knows; only the profile supports :vcf,
  # so it is not part of the per-page default.
  @formats Map.keys(@content_types)
  @default_formats [:md, :txt, :json, :xml]

  # Native-language names for the language hint (the hint addresses the
  # reader of the *other* language); a locale added without a name here
  # falls back to its code.
  @language_names %{"en" => "English", "de" => "Deutsch"}

  def schema_version, do: @schema_version

  @doc "Every format the system knows (`VutuvWeb.Plug.AgentFormat` derives its extension list from this)."
  def formats, do: @formats

  @doc """
  The format this request asks for: `:md | :txt | :json | :xml | :vcf | :html`.

  URL extension first (set by `VutuvWeb.Plug.AgentFormat`), then `Accept`
  header negotiation. A format outside `allowed` resolves to `:html`; for an
  extension request the plug's before_send guard then turns the HTML answer
  into a 404, so an unsupported extension never serves HTML.
  """
  def negotiate(conn, allowed \\ @default_formats) do
    format = conn.private[:vutuv_agent_format] || conn.private[:vutuv_agent_accept]

    if format in allowed do
      # Agent documents default to English (the canonical, cache-safe
      # rendering); `?lang=de` opts into a translated one. The session
      # locale is deliberately ignored so the same URL always answers
      # with the same bytes, logged in or not.
      Gettext.put_locale(VutuvWeb.Gettext, doc_locale(conn))
      format
    else
      :html
    end
  end

  defp doc_locale(conn) do
    lang = conn.params["lang"]
    if lang in Gettext.known_locales(VutuvWeb.Gettext), do: lang, else: "en"
  end

  @doc """
  The standard controller integration: negotiates, then either renders the
  HTML page (alternate links and `Vary` set) via the `:html` fun or sends
  the doc built by the `:doc` fun — which runs only for agent-format
  requests. `:allowed` (default md/txt/json) drives both the negotiation
  and the advertised alternates. The `:doc` fun may take the negotiated
  format as an argument (arity 1) when the doc depends on it (e.g. the
  profile embeds a photo only for `:vcf`).
  """
  def respond(conn, opts) do
    allowed = Keyword.get(opts, :allowed, @default_formats)

    case negotiate(conn, allowed) do
      :html ->
        html_fun = Keyword.fetch!(opts, :html)
        html_fun.(put_html_alternates(conn, allowed))

      format ->
        doc_fun = Keyword.fetch!(opts, :doc)
        send_doc(conn, format, build_doc(doc_fun, format))
    end
  end

  defp build_doc(fun, format) when is_function(fun, 1), do: fun.(format)
  defp build_doc(fun, _format) when is_function(fun, 0), do: fun.()

  @doc "The URL extension for `format` (`:md` -> `\".md\"`)."
  def extension(format) when format in @formats, do: "." <> Atom.to_string(format)

  @doc """
  Renders `doc` as `format` and sends it, with all agent headers set.
  """
  def send_doc(conn, format, doc) do
    doc = put_request_query(doc, conn)
    body = format |> render_doc(doc) |> append_language_hint(conn, format)

    conn
    |> put_resp_content_type(Map.fetch!(@content_types, format))
    |> put_resp_header("vary", vary_header(format))
    |> put_policy_headers(doc)
    # Docs render the anonymous public view only, so they are publicly
    # cacheable (Plug's default would be private, must-revalidate).
    |> put_resp_header("cache-control", "public, max-age=300")
    # The HTML original, as a Link header (VutuvWeb.Plug.AgentLinks adds
    # the global discovery links on these responses too).
    |> prepend_resp_headers([{"link", ~s(<#{doc.url}>; rel="canonical"; type="text/html")}])
    |> maybe_put_content_location(format)
    |> maybe_put_tokens(format, body)
    |> maybe_put_disposition(format, doc)
    |> put_private(:vutuv_agent_doc_sent, true)
    |> send_resp(200, body)
    |> halt()
  end

  # An Accept-negotiated response (extension-free URL) names its canonical
  # extension sibling so caches and agents learn the format-specific URL;
  # an extension URL already self-identifies.
  defp maybe_put_content_location(conn, format) do
    if conn.private[:vutuv_agent_accept] && !conn.private[:vutuv_agent_format] do
      location = canonical_path(conn.request_path) <> extension(format) <> query_suffix(conn)
      put_resp_header(conn, "content-location", location)
    else
      conn
    end
  end

  @doc """
  For the HTML rendering of a supported page: sets `Vary: Accept` and
  assigns `:agent_doc_alternates`, which the root layout renders as
  `<link rel="alternate">` tags.
  """
  def put_html_alternates(conn, formats \\ @default_formats) do
    path = canonical_path(conn.request_path)
    query = query_suffix(conn)

    alternates =
      for format <- formats do
        %{
          type: Map.fetch!(@content_types, format),
          href: path <> extension(format) <> query
        }
      end

    conn
    |> put_resp_header("vary", "accept")
    |> assign(:agent_doc_alternates, alternates)
  end

  @doc """
  Adds an RSS feed to the page's advertised alternates (the same
  `<link rel="alternate">` list the agent formats use). Call after
  `put_html_alternates/2` — `respond/2` has already run it when the
  `:html` fun gets the conn.
  """
  def put_feed_alternate(conn, href, title) do
    alternates = conn.assigns[:agent_doc_alternates] || []
    feed = %{type: "application/rss+xml", href: href, title: title}
    assign(conn, :agent_doc_alternates, alternates ++ [feed])
  end

  # "/stefan/" routes to the profile (Plug drops the empty segment) but
  # request_path keeps the slash; strip it so the alternate href is the
  # routable "/stefan.md", not the dead "/stefan/.md".
  defp canonical_path("/"), do: "/"
  defp canonical_path(path), do: String.replace_suffix(path, "/", "")

  defp query_suffix(conn) do
    case conn.query_string do
      empty when empty in [nil, ""] -> ""
      query -> "?" <> query
    end
  end

  @doc """
  The shared head of every doc: type, schema_version, generated_at, the
  canonical HTML URL and the sibling format URLs. `:noindex` mirrors the
  HTML page's robots state, `:noai` the member's AI opt-out; together they
  drive the `Content-Signal` and `X-Robots-Tag` headers.
  """
  def doc_meta(type, path, opts \\ []) do
    base = VutuvWeb.Endpoint.url()
    formats = Keyword.get(opts, :formats, @default_formats)

    %{
      type: type,
      schema_version: @schema_version,
      generated_at: DateTime.truncate(DateTime.utc_now(), :second),
      url: base <> path,
      formats:
        Map.new(formats, fn format ->
          {format_name(format), base <> path <> extension(format)}
        end),
      noindex: Keyword.get(opts, :noindex, false),
      noai: Keyword.get(opts, :noai, false)
    }
  end

  # A paginated or translated request (?page=2, ?lang=de) changes what the
  # page shows, so the doc's own canonical `url` and its sibling `formats`
  # links must carry the same query — otherwise they point at page 1 /
  # English. Mirrors put_html_alternates/2, which keeps the query too.
  defp put_request_query(doc, conn) do
    case query_suffix(conn) do
      "" ->
        doc

      suffix ->
        %{
          doc
          | url: doc.url <> suffix,
            formats: Map.new(doc.formats, fn {name, url} -> {name, url <> suffix} end)
        }
    end
  end

  @doc "Absolute URL for an app path."
  def abs_url(path), do: VutuvWeb.Endpoint.url() <> path

  @doc "The doc representation of a person: name, slug, profile URL."
  def person_ref(user) do
    %{
      name: VutuvWeb.UserHelpers.full_name(user),
      username: user.username,
      url: abs_url("/" <> user.username)
    }
  end

  @doc "The one-line excerpt the list-like docs show of a post body."
  def excerpt(body) do
    body
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 200)
  end

  defp format_name(:md), do: :markdown
  defp format_name(:txt), do: :text
  defp format_name(:json), do: :json
  defp format_name(:xml), do: :xml
  defp format_name(:vcf), do: :vcard

  defp render_doc(:md, doc), do: Markdown.render(doc)
  defp render_doc(:txt, doc), do: Text.render(doc)
  defp render_doc(:json, doc), do: JSON.render(doc)
  defp render_doc(:xml, doc), do: Xml.render(doc)
  defp render_doc(:vcf, doc), do: VCard.render(doc)

  # A reader whose Accept-Language asks for another language we have a
  # translation for gets a final pointer to that rendering, written in the
  # target language. Only the human-readable formats carry the hint (JSON
  # consumers have the formats map); it is the one byte of the response
  # that varies per Accept-Language, declared via vary_header/1.
  defp append_language_hint(body, conn, format) when format in [:md, :txt] do
    rendered = Gettext.get_locale(VutuvWeb.Gettext)

    case browser_locale(conn) do
      nil -> body
      ^rendered -> body
      target -> body <> language_hint(conn, format, target)
    end
  end

  defp append_language_hint(body, _conn, _format), do: body

  defp vary_header(format) when format in [:md, :txt], do: "accept, accept-language"
  defp vary_header(_format), do: "accept"

  # The first Accept-Language entry we have a translation for. Browsers
  # send entries in preference order, so q-values are ignored (the same
  # simplification VutuvWeb.Plug.Locale makes); de-DE counts as de.
  defp browser_locale(conn) do
    known = Gettext.known_locales(VutuvWeb.Gettext)

    conn
    |> get_req_header("accept-language")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.find_value(fn entry ->
      locale =
        entry
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.split("-", parts: 2)
        |> hd()
        |> String.downcase()

      locale in known && locale
    end)
  end

  defp language_hint(conn, format, target) do
    line =
      Gettext.with_locale(VutuvWeb.Gettext, target, fn ->
        gettext("This page in %{language}: %{url}",
          language: Map.get(@language_names, target, target),
          url: language_url(conn, format, target)
        )
      end)

    case format do
      :md -> "\n<!-- " <> line <> " -->\n"
      :txt -> "\n" <> line <> "\n"
    end
  end

  # The sibling URL in the target language: the canonical extension URL,
  # other query params kept, ?lang= swapped (English is the lang-less
  # canonical rendering).
  defp language_url(conn, format, target) do
    conn = fetch_query_params(conn)

    query =
      conn.query_params
      |> Map.delete("lang")
      |> then(&if target == "en", do: &1, else: Map.put(&1, "lang", target))
      |> URI.encode_query()

    abs_url(conn.request_path <> extension(format)) <>
      if query == "", do: "", else: "?" <> query
  end

  # The doc's two opt-out axes as the Content-Signal and X-Robots-Tag
  # headers — both rendered by ContentPolicy, the same source robots.txt
  # renders from, so header and directives cannot disagree.
  defp put_policy_headers(conn, doc) do
    noindex? = Map.get(doc, :noindex, false)
    noai? = Map.get(doc, :noai, false)

    conn
    |> put_resp_header("content-signal", VutuvWeb.ContentPolicy.signal_header(noindex?, noai?))
    |> VutuvWeb.ContentPolicy.put_robots_header(noindex?, noai?)
  end

  defp maybe_put_tokens(conn, :md, body),
    do: put_resp_header(conn, "x-markdown-tokens", Integer.to_string(estimate_tokens(body)))

  defp maybe_put_tokens(conn, _format, _body), do: conn

  defp maybe_put_disposition(conn, :vcf, doc) do
    filename = VCard.filename(doc)
    put_resp_header(conn, "content-disposition", "attachment; filename=\"#{filename}\"")
  end

  defp maybe_put_disposition(conn, _format, _doc), do: conn

  # The usual ~4 characters per token heuristic; an estimate is all the
  # header promises.
  defp estimate_tokens(body), do: div(byte_size(body), 4) + 1
end
