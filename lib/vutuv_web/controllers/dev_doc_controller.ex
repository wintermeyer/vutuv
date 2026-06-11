defmodule VutuvWeb.DevDocController do
  @moduledoc """
  The developer documentation under `/developers` (English, curl-first —
  see `priv/dev_docs/*.md`). The Markdown files are compiled in and served
  two ways: rendered as HTML pages, and raw under the `.md` sibling URL
  (or `Accept: text/markdown`), like every other public page.
  """

  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs

  @pages ~w(index authentication reference webhooks)

  @titles %{
    "index" => "vutuv API",
    "authentication" => "Authentication & tokens",
    "reference" => "API reference",
    "webhooks" => "Webhooks"
  }

  for page <- @pages do
    @external_resource Path.join("priv/dev_docs", page <> ".md")
  end

  @docs Map.new(@pages, fn page -> {page, File.read!("priv/dev_docs/#{page}.md")} end)

  def index(conn, _params), do: show_page(conn, "index")

  def show(conn, %{"page" => page}) when page in @pages, do: show_page(conn, page)

  def show(conn, _params), do: VutuvWeb.ControllerHelpers.render_error(conn, 404)

  defp show_page(conn, page) do
    markdown = Map.fetch!(@docs, page)

    case AgentDocs.negotiate(conn, [:md]) do
      :md ->
        send_markdown(conn, markdown)

      :html ->
        conn
        |> AgentDocs.put_html_alternates([:md])
        |> render("show.html",
          page: page,
          page_title: Map.fetch!(@titles, page),
          body: markdown |> strip_leading_h1() |> Earmark.as_html!()
        )
    end
  end

  # The page header already shows the title; rendering the Markdown's own
  # `# Heading` again would duplicate it. The raw .md keeps it, of course.
  defp strip_leading_h1("# " <> rest) do
    case String.split(rest, "\n", parts: 2) do
      [_title, body] -> body
      [_title] -> ""
    end
  end

  defp strip_leading_h1(markdown), do: markdown

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
