defmodule VutuvWeb.Plug.AgentFormat do
  @moduledoc """
  URL-extension detection for the agent document formats (see
  `VutuvWeb.AgentDocs`): `/stefan.wintermeyer.md` is the same route as
  `/stefan.wintermeyer`, answered as Markdown.

  Runs in the endpoint, before the router: when a GET path's last segment
  ends in one of the known extensions (`.md`, `.txt`, `.json`, `.vcf`), the
  extension is stripped from `path_info`/`request_path` so the normal route
  matches, and the requested format is stored in
  `conn.private.vutuv_agent_format`. Only the known extensions are cut, and
  only as a suffix — user slugs legitimately contain dots
  (`stefan.wintermeyer`), so nothing else of the segment is touched.

  A `before_send` guard turns the response into a plain 404 if no controller
  actually delivered an agent document (`conn.private.vutuv_agent_doc_sent`):
  a `.md` URL must never quietly serve the HTML page. An in-app redirect
  keeps the requested extension on its location (so a canonical-casing
  redirect of `/:slug/posts/<UPPERCASE>.md` lands on the canonical `.md`
  URL); error responses pass through unchanged.

  Accept negotiation also happens here: a GET whose `Accept` header asks for
  `text/markdown` / `application/json` / `text/plain` / `text/vcard` (and not
  `text/html` — browsers always list it) gets the format recorded in
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
  # panel, the static mounts and framework/dev endpoints.
  @skip_prefixes ~w(api admin assets css fonts images js favicon.ico avatars covers
                    screenshots post_images live phoenix tidewave sent_emails dev)

  # Literal routes whose name ends in a known extension.
  @skip_paths ["/robots.txt", "/llms.txt", "/security.txt"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: [_ | _] = path_info} = conn, _opts) do
    with false <- conn.request_path in @skip_paths,
         false <- hd(path_info) in @skip_prefixes do
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

  # Browsers always list text/html, so its presence wins for json/txt/vcf;
  # text/markdown is requested by agents only (the Cloudflare convention)
  # and wins outright. The header is then normalized to text/html so the
  # browser pipeline's `accepts ["html"]` lets the request through.
  defp negotiate_accept(conn) do
    accept = conn |> get_req_header("accept") |> Enum.join(",") |> String.downcase()

    format =
      cond do
        accept == "" -> nil
        String.contains?(accept, "text/markdown") -> :md
        String.contains?(accept, "text/html") -> nil
        String.contains?(accept, "text/vcard") -> :vcf
        String.contains?(accept, "application/json") -> :json
        String.contains?(accept, "text/plain") -> :txt
        true -> nil
      end

    if format do
      conn
      |> put_private(:vutuv_agent_accept, format)
      |> put_req_header("accept", "text/html")
    else
      conn
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
