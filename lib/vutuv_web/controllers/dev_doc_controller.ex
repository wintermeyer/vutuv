defmodule VutuvWeb.DevDocController do
  @moduledoc """
  The developer documentation under `/developers` (English, curl-first —
  see `priv/dev_docs/*.md`). The Markdown files are compiled in and served
  two ways: rendered as HTML pages, and raw under the `.md` sibling URL
  (or `Accept: text/markdown`), like every other public page.
  """

  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs

  @titles %{
    "index" => "vutuv API",
    "authentication" => "Authentication & tokens",
    "reference" => "API reference",
    "webhooks" => "Webhooks"
  }

  @pages Map.keys(@titles)

  for page <- @pages do
    @external_resource Path.join("priv/dev_docs", page <> ".md")
  end

  @docs Map.new(@pages, fn page -> {page, File.read!("priv/dev_docs/#{page}.md")} end)

  # The HTML rendering is static too, so Earmark runs once at compile time,
  # not per request on a public, crawlable page.
  @docs_html Map.new(@docs, fn {page, markdown} ->
               {page, markdown |> String.replace(~r/\A# [^\n]*\n/, "") |> Earmark.as_html!()}
             end)

  def index(conn, _params), do: show_page(conn, "index")

  def show(conn, %{"page" => page}) when page in @pages, do: show_page(conn, page)

  def show(conn, _params), do: VutuvWeb.ControllerHelpers.render_error(conn, 404)

  defp show_page(conn, page) do
    case AgentDocs.negotiate(conn, [:md]) do
      :md ->
        send_markdown(conn, Map.fetch!(@docs, page))

      :html ->
        # The leading `# Heading` was stripped at compile time: the page
        # header already shows the title. The raw .md keeps it, of course.
        conn
        |> AgentDocs.put_html_alternates([:md])
        |> render("show.html",
          page: page,
          page_title: Map.fetch!(@titles, page),
          body: Map.fetch!(@docs_html, page)
        )
    end
  end

  # The raw file, not a doc map — these pages ARE Markdown. The private flag
  # satisfies VutuvWeb.Plug.AgentFormat's "extension URLs must answer with
  # an agent document" guard.
  defp send_markdown(conn, markdown) do
    conn
    |> put_resp_content_type("text/markdown")
    |> put_private(:vutuv_agent_doc_sent, true)
    |> send_resp(200, markdown)
    |> halt()
  end
end
