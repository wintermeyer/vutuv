defmodule VutuvWeb.HelpController do
  @moduledoc """
  The member-facing help pages under `/system/`, written as Markdown in
  `priv/help/` — one file per locale, because a page of running prose belongs
  in a document an editor can read end to end, not in two hundred `gettext/1`
  fragments.

  So far there is one: `/system/markdown`, what a member may write in a post
  and what it will look like. Its examples are rendered by the same code that
  renders a post (`VutuvWeb.DevDocMarkdown`, which shares the fence parsing,
  the highlighting, the diff rows and the footnotes with `VutuvWeb.Markdown`),
  so the page cannot drift from the thing it documents: if a code block ever
  stops rendering, the help page stops showing it too.

  Like the developer docs, both the HTML and the raw `.md` sibling are served,
  and both are built at compile time — the pages are static, and they are
  public and crawlable, so no request should pay to re-render them.
  """

  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.DevDocMarkdown

  @locales ~w(de en)
  @default_locale "en"

  for locale <- @locales do
    @external_resource Path.join("priv/help", "markdown_#{locale}.md")
  end

  @sources Map.new(@locales, fn locale ->
             {locale, File.read!("priv/help/markdown_#{locale}.md")}
           end)

  # The page's own `# Heading` is dropped: the page header already shows the
  # title, the same split the dev docs make. The raw `.md` keeps it.
  @bodies Map.new(@sources, fn {locale, markdown} ->
            {locale,
             markdown
             |> String.replace(~r/\A# [^\n]*\n/, "")
             |> DevDocMarkdown.to_html()}
          end)

  @titles Map.new(@sources, fn {locale, markdown} ->
            {locale, markdown |> String.split("\n") |> hd() |> String.trim_leading("# ")}
          end)

  # The `##` sections, in order, as `{anchor, label}`. Built here rather than by
  # re-parsing the HTML: `DevDocMarkdown.slug/1` is the same function that put
  # the ids on the headings, so the two cannot disagree.
  @contents Map.new(@sources, fn {locale, markdown} ->
              {locale,
               ~r/^## (.+)$/m
               |> Regex.scan(markdown, capture: :all_but_first)
               |> Enum.map(fn [heading] -> {DevDocMarkdown.slug(heading), heading} end)}
            end)

  @doc """
  `/system/markdown` — the formatting help, in the reader's language, with the
  raw Markdown under the `.md` sibling.
  """
  def markdown(conn, _params) do
    locale = locale(conn)

    case AgentDocs.negotiate(conn, [:md]) do
      :md ->
        conn
        |> put_resp_content_type("text/markdown")
        |> put_private(:vutuv_agent_doc_sent, true)
        |> send_resp(200, Map.fetch!(@sources, locale))
        |> halt()

      :html ->
        conn
        |> AgentDocs.put_html_alternates([:md])
        |> render("markdown.html",
          page_title: Map.fetch!(@titles, locale),
          contents: Map.fetch!(@contents, locale),
          body: Map.fetch!(@bodies, locale)
        )
    end
  end

  # An installation may run locales this page has not been written in yet, so
  # fall back rather than crash on a missing file.
  defp locale(_conn) do
    locale = Gettext.get_locale(VutuvWeb.Gettext)
    if locale in @locales, do: locale, else: @default_locale
  end
end
