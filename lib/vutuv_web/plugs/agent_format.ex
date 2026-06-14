defmodule VutuvWeb.Plug.AgentFormat do
  @moduledoc """
  URL-extension detection for the agent document formats (see
  `VutuvWeb.AgentDocs`): `/stefan.wintermeyer.md` is the same route as
  `/stefan.wintermeyer`, answered as Markdown.

  Runs in the endpoint, before the router: when a GET path's last segment
  ends in one of the known extensions (`.md`, `.txt`, `.json`, `.xml`,
  `.vcf`), the extension is stripped from `path_info`/`request_path` so the
  normal route matches, and the requested format is stored in
  `conn.private.vutuv_agent_format`. Only the known extensions are cut, and
  only as a suffix — user slugs legitimately contain dots
  (`stefan.wintermeyer`), so nothing else of the segment is touched.

  `.xml` is shared with routes that serve their own XML and must not be
  rewritten: `/sitemap.xml` (a `@skip_paths` literal), the chunked
  `/sitemaps/*.xml` children (the `sitemaps` `@skip_prefix`) and the RSS
  feeds `/posts/feed.xml` + `/:slug/posts/feed.xml` (skipped by their literal
  `feed.xml` last segment, since the per-member one has a dynamic slug up
  front). RSS is `application/rss+xml`, distinct from our `application/xml`.

  A `before_send` guard turns the response into a plain 404 if no controller
  actually delivered an agent document (`conn.private.vutuv_agent_doc_sent`):
  a `.md` URL must never quietly serve the HTML page. An in-app redirect
  keeps the requested extension on its location (so a canonical-casing
  redirect of `/:slug/posts/<UPPERCASE>.md` lands on the canonical `.md`
  URL); error responses pass through unchanged.

  Accept negotiation also happens here: a GET whose `Accept` header asks for
  `text/markdown` / `application/json` / `application/xml` / `text/plain` /
  `text/vcard` (and not `text/html` — browsers always list it) gets the format recorded in
  `conn.private.vutuv_agent_accept`, and the header is normalized to
  `text/html` so the browser pipeline's `accepts ["html"]` admits the
  request. Header-negotiated requests are best-effort: a page without agent
  documents simply answers HTML, no 404 guard.
  """

  @behaviour Plug

  import Plug.Conn

  @extensions for format <- VutuvWeb.AgentDocs.formats(),
                  do: {VutuvWeb.AgentDocs.extension(format), format}

  # First path segments that never carry agent documents: the API, the admin
  # panel, the static mounts and framework/dev endpoints, plus `search` —
  # `/search/:id` carries the raw query as its last segment, so a term like
  # "package.json" must not be read as a `.json` format request — and
  # `.well-known`, whose literal routes end in real .json/.md filenames.
  @skip_prefixes ~w(api admin assets css fonts images js favicon.ico avatars covers
                    screenshots post_images live phoenix tidewave sent_emails dev search
                    sitemaps .well-known)

  # Literal routes whose name ends in a known extension.
  @skip_paths ["/robots.txt", "/llms.txt", "/security.txt", "/sitemap.xml"]

  # Accept-header media types in priority order: the FIRST one present in the
  # header wins, even when it maps to `nil`. text/markdown is requested by
  # agents only (the Cloudflare convention) and wins outright; text/html is
  # always listed by browsers, so its presence (once markdown is ruled out)
  # suppresses json/txt/vcf by mapping to `nil`.
  @accept_formats [
    {"text/markdown", :md},
    {"text/html", nil},
    {"text/vcard", :vcf},
    {"application/json", :json},
    {"application/xml", :xml},
    {"text/xml", :xml},
    {"text/plain", :txt}
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: [_ | _] = path_info} = conn, _opts) do
    with false <- conn.request_path in @skip_paths,
         false <- hd(path_info) in @skip_prefixes,
         false <- List.last(path_info) == "feed.xml" do
      case strip_extension(List.last(path_info)) do
        {format, stripped} ->
          rewritten = List.replace_at(path_info, -1, stripped)

          %{conn | path_info: rewritten, request_path: "/" <> Enum.join(rewritten, "/")}
          |> put_private(:vutuv_agent_format, format)
          |> register_before_send(&enforce_handled/1)

        nil ->
          negotiate_accept(conn)
      end
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  # Maps the request's Accept header to an agent format (see @accept_formats).
  # The header is then normalized to text/html so the browser pipeline's
  # `accepts ["html"]` lets the request through.
  defp negotiate_accept(conn) do
    accept = conn |> get_req_header("accept") |> Enum.join(",") |> String.downcase()
    format = accept != "" && accept_format(accept)

    if format do
      conn
      |> put_private(:vutuv_agent_accept, format)
      |> put_req_header("accept", "text/html")
    else
      conn
    end
  end

  # The first listed media type the header contains, returning its mapped
  # format (which may be `nil`, e.g. text/html). `Enum.find` (not find_value)
  # so a `nil` mapping still short-circuits the rest of the list.
  defp accept_format(accept) do
    case Enum.find(@accept_formats, fn {media, _fmt} -> String.contains?(accept, media) end) do
      {_media, format} -> format
      nil -> nil
    end
  end

  defp strip_extension(segment) do
    Enum.find_value(@extensions, fn {suffix, format} ->
      base = String.replace_suffix(segment, suffix, "")
      if base != segment and base != "", do: {format, base}
    end)
  end

  # Only successful responses are flipped: a redirect keeps redirecting
  # (carrying the extension along, see keep_extension/1) and an error page
  # is already the right answer.
  defp enforce_handled(conn) do
    cond do
      conn.private[:vutuv_agent_doc_sent] ->
        conn

      conn.status in 300..399 ->
        keep_extension(conn)

      conn.status in 200..299 ->
        conn
        |> put_resp_content_type("text/plain")
        |> Map.put(:status, 404)
        |> Map.put(:resp_body, "Not Found")

      true ->
        conn
    end
  end

  # An in-app redirect of an extension URL redirects to the same format:
  # append the extension to the location's path (once, before any query
  # string) so every canonicalizing redirect keeps it without each
  # controller having to remember to.
  defp keep_extension(conn) do
    extension = VutuvWeb.AgentDocs.extension(conn.private.vutuv_agent_format)

    case get_resp_header(conn, "location") do
      ["/" <> _ = location] ->
        [path | query] = String.split(location, "?", parts: 2)

        if String.ends_with?(path, extension) do
          conn
        else
          put_resp_header(conn, "location", Enum.join([path <> extension | query], "?"))
        end

      _ ->
        conn
    end
  end
end
