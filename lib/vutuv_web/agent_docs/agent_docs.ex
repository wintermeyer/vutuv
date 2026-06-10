defmodule VutuvWeb.AgentDocs do
  @moduledoc """
  Agent-readable sibling formats of the public pages — **the one chokepoint
  for every non-HTML page representation.**

  Every public page that supports it is also available as Markdown, plain
  text (80 columns) and JSON under the same URL plus an extension, and the
  profile additionally as a vCard:

      /stefan.wintermeyer        the HTML page
      /stefan.wintermeyer.md     Markdown (also via `Accept: text/markdown`)
      /stefan.wintermeyer.txt    plain text (also via `Accept: text/plain`)
      /stefan.wintermeyer.json   JSON (also via `Accept: application/json`)
      /stefan.wintermeyer.vcf    vCard (also via `Accept: text/vcard`)

  The extension is parsed by `VutuvWeb.Plug.AgentFormat` (endpoint); the
  `Accept` negotiation happens here, Cloudflare's "markdown for agents"
  style. Every variant renders the **anonymous public view** — never
  session-dependent data — so the responses stay cache-safe.

  ## How a page supports the formats

  The controller action branches on `negotiate/2` and either sends a doc or
  renders HTML (with `put_html_alternates/2` for the `<link rel="alternate">`
  head tags and the `Vary: Accept` header):

      case AgentDocs.negotiate(conn) do
        :html -> conn |> AgentDocs.put_html_alternates() |> render(...)
        format -> AgentDocs.send_doc(conn, format, SomeDoc.build(...))
      end

  A *doc* is one plain map per page (built by the `VutuvWeb.AgentDocs.*Doc`
  modules) that all formats render from — **that map is the single source of
  truth**. If you change what a public HTML page shows, change the page's
  doc module too; `test/vutuv_web/agent_docs/agent_docs_drift_test.exs`
  fails when the HTML page and the agent documents drift apart.

  ## Versioning and headers

  Docs carry `schema_version` (bumped only on breaking changes; additions
  are free) and `generated_at`. Responses carry `Content-Signal`
  (all `yes`, or all `no` when the page is noindexed or the member opted out
  of search engines via `noindex?`), `Vary: Accept`, and for Markdown an
  `x-markdown-tokens` estimate.
  """

  import Plug.Conn

  alias VutuvWeb.AgentDocs.JSON
  alias VutuvWeb.AgentDocs.Markdown
  alias VutuvWeb.AgentDocs.Text
  alias VutuvWeb.AgentDocs.VCard

  @schema_version 1

  @content_types %{
    md: "text/markdown",
    txt: "text/plain",
    json: "application/json",
    vcf: "text/vcard"
  }

  # The one list of formats the system knows; only the profile supports :vcf,
  # so it is not part of the per-page default.
  @formats Map.keys(@content_types)
  @default_formats [:md, :txt, :json]

  def schema_version, do: @schema_version

  @doc "Every format the system knows (`VutuvWeb.Plug.AgentFormat` derives its extension list from this)."
  def formats, do: @formats

  @doc """
  The format this request asks for: `:md | :txt | :json | :vcf | :html`.

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

  @doc "The URL extension for `format` (`:md` -> `\".md\"`)."
  def extension(format) when format in @formats, do: "." <> Atom.to_string(format)

  @doc """
  Renders `doc` as `format` and sends it, with all agent headers set.
  """
  def send_doc(conn, format, doc) do
    body = render_doc(format, doc)

    conn
    |> put_resp_content_type(Map.fetch!(@content_types, format))
    |> put_resp_header("vary", "accept")
    |> put_resp_header("content-signal", content_signal(doc))
    |> maybe_put_noindex(doc)
    |> maybe_put_tokens(format, body)
    |> maybe_put_disposition(format, doc)
    |> put_private(:vutuv_agent_doc_sent, true)
    |> send_resp(200, body)
    |> halt()
  end

  @doc """
  For the HTML rendering of a supported page: sets `Vary: Accept` and
  assigns `:agent_doc_alternates`, which the root layout renders as
  `<link rel="alternate">` tags.
  """
  def put_html_alternates(conn, formats \\ @default_formats) do
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string

    alternates =
      for format <- formats do
        %{
          type: Map.fetch!(@content_types, format),
          href: conn.request_path <> extension(format) <> query
        }
      end

    conn
    |> put_resp_header("vary", "accept")
    |> assign(:agent_doc_alternates, alternates)
  end

  @doc """
  The shared head of every doc: type, schema_version, generated_at, the
  canonical HTML URL and the sibling format URLs. `:noindex` mirrors the
  HTML page's robots state and drives the `Content-Signal` header.
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
      noindex: Keyword.get(opts, :noindex, false)
    }
  end

  @doc "Absolute URL for an app path."
  def abs_url(path), do: VutuvWeb.Endpoint.url() <> path

  @doc "The doc representation of a person: name, slug, profile URL."
  def person_ref(user) do
    %{
      name: VutuvWeb.UserHelpers.full_name(user),
      slug: user.active_slug,
      url: abs_url("/" <> user.active_slug)
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
  defp format_name(:vcf), do: :vcard

  defp render_doc(:md, doc), do: Markdown.render(doc)
  defp render_doc(:txt, doc), do: Text.render(doc)
  defp render_doc(:json, doc), do: JSON.render(doc)
  defp render_doc(:vcf, doc), do: VCard.render(doc)

  # All-or-nothing on purpose ("safer", per product decision): a noindexed
  # page or an opted-out member sends every signal as no.
  defp content_signal(%{noindex: true}), do: "ai-train=no, search=no, ai-input=no"
  defp content_signal(_doc), do: "ai-train=yes, search=yes, ai-input=yes"

  defp maybe_put_noindex(conn, %{noindex: true}),
    do: put_resp_header(conn, "x-robots-tag", "noindex")

  defp maybe_put_noindex(conn, _doc), do: conn

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
