defmodule VutuvWeb.SitemapController do
  @moduledoc """
  /sitemap.xml — a sitemap index pointing at chunked child sitemaps under
  /sitemaps/<type>-<n>.xml (plus static.xml). The queries live in
  `Vutuv.Sitemap`; this controller only renders XML. Served outside the
  browser pipeline so crawlers are never turned away by content
  negotiation.
  """

  use VutuvWeb, :controller

  alias Vutuv.Sitemap
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.Xml

  @entry_funs %{
    "users" => &Sitemap.user_entries/1,
    "posts" => &Sitemap.post_entries/1,
    "tags" => &Sitemap.tag_entries/1,
    "organizations" => &Sitemap.organization_entries/1,
    "jobs" => &Sitemap.job_entries/1
  }

  def index(conn, _params) do
    children =
      ["static.xml"] ++
        for {type, count} <- Enum.sort(Sitemap.chunk_counts()),
            chunk <- 1..count//1,
            do: "#{type}-#{chunk}.xml"

    locs =
      for child <- children do
        "  <sitemap><loc>#{Xml.escape(AgentDocs.abs_url("/sitemaps/" <> child))}</loc></sitemap>\n"
      end

    send_xml(conn, [
      ~s(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n),
      locs,
      "</sitemapindex>\n"
    ])
  end

  def show(conn, %{"name" => "static.xml"}) do
    send_xml(conn, urlset(Enum.map(Sitemap.static_paths(), &{&1, nil})))
  end

  def show(conn, %{"name" => name}) do
    with %{"type" => type, "chunk" => chunk} <-
           Regex.named_captures(
             ~r/^(?<type>users|posts|tags|organizations|jobs)-(?<chunk>[1-9]\d*)\.xml$/,
             name
           ),
         [_ | _] = entries <- Map.fetch!(@entry_funs, type).(String.to_integer(chunk)) do
      send_xml(conn, urlset(entries))
    else
      # nil (bad name) or [] (chunk beyond the data) — nothing to serve. A
      # plain 404, not the HTML error page: the consumer is a crawler, and
      # outside the browser pipeline there is no flash for the app layout.
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not Found")
    end
  end

  defp urlset(entries) do
    urls =
      for {path, lastmod} <- entries do
        [
          "  <url><loc>",
          Xml.escape(AgentDocs.abs_url(path)),
          "</loc>",
          if(lastmod, do: "<lastmod>#{Date.to_iso8601(lastmod)}</lastmod>", else: ""),
          "</url>\n"
        ]
      end

    [~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n), urls, "</urlset>\n"]
  end

  defp send_xml(conn, body) do
    conn
    |> put_resp_content_type("application/xml")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, [~s(<?xml version="1.0" encoding="UTF-8"?>\n), body])
  end
end
