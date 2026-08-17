defmodule VutuvWeb.HelpController do
  @moduledoc """
  The member-facing help pages under `/system/`, written as Markdown in
  `priv/help/` — one file per page per locale, because a page of running prose
  belongs in a document an editor can read end to end, not in two hundred
  `gettext/1` fragments.

  There are two: `/system/markdown`, what a member may write in a post and what
  it will look like, and `/system/mastodon`, how to sign in from a
  Mastodon-compatible app. The Markdown page's examples are rendered by the
  same code that renders a post (`VutuvWeb.DevDocMarkdown`, which shares the
  fence parsing, the highlighting, the diff rows and the footnotes with
  `VutuvWeb.Markdown`), so the page cannot drift from the thing it documents:
  if a code block ever stops rendering, the help page stops showing it too.

  Like the developer docs, both the HTML and the raw `.md` sibling are served,
  and both are built at compile time — the pages are static, and they are
  public and crawlable, so no request should pay to re-render them.

  The file list is **explicit** rather than a `Path.wildcard/1`: a module that
  builds functions from a wildcard tracks each matched file as an
  `@external_resource`, so editing one recompiles it but *adding* one does not,
  and with `_build` cached in CI a brand-new page can pass a full local
  `mix precommit` and then fail CI with an undefined function (issue #1086).
  Naming the pages here means adding one is a source edit, which always
  recompiles.

  One placeholder is substituted at render time rather than written into the
  Markdown: `{{host}}` becomes this installation's own host. vutuv is
  installable by third parties, so a help page that tells a member to type
  `vutuv.de` into their app is wrong everywhere else.
  """

  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.DevDocMarkdown
  alias VutuvWeb.Endpoint

  @locales ~w(de en)
  @default_locale "en"
  @pages ~w(markdown mastodon)

  for page <- @pages, locale <- @locales do
    @external_resource Path.join("priv/help", "#{page}_#{locale}.md")
  end

  @sources Map.new(@pages, fn page ->
             {page,
              Map.new(@locales, fn locale ->
                {locale, File.read!("priv/help/#{page}_#{locale}.md")}
              end)}
           end)

  # The page's own `# Heading` is dropped: the page header already shows the
  # title, the same split the dev docs make. The raw `.md` keeps it.
  @bodies Map.new(@sources, fn {page, by_locale} ->
            {page,
             Map.new(by_locale, fn {locale, markdown} ->
               {locale,
                markdown
                |> String.replace(~r/\A# [^\n]*\n/, "")
                |> DevDocMarkdown.to_html()}
             end)}
          end)

  @titles Map.new(@sources, fn {page, by_locale} ->
            {page,
             Map.new(by_locale, fn {locale, markdown} ->
               {locale, markdown |> String.split("\n") |> hd() |> String.trim_leading("# ")}
             end)}
          end)

  # The `##` sections, in order, as `{anchor, label}`. Built here rather than by
  # re-parsing the HTML: `DevDocMarkdown.slug/1` is the same function that put
  # the ids on the headings, so the two cannot disagree.
  @contents Map.new(@sources, fn {page, by_locale} ->
              {page,
               Map.new(by_locale, fn {locale, markdown} ->
                 {locale,
                  ~r/^## (.+)$/m
                  |> Regex.scan(markdown, capture: :all_but_first)
                  |> Enum.map(fn [heading] -> {DevDocMarkdown.slug(heading), heading} end)}
               end)}
            end)

  @doc """
  `/system/markdown` — the formatting help, in the reader's language, with the
  raw Markdown under the `.md` sibling.
  """
  def markdown(conn, _params), do: page(conn, "markdown")

  @doc """
  `/system/mastodon` — how to reach this installation from a
  Mastodon-compatible app, and what such an app can and cannot do here.
  """
  def mastodon(conn, _params), do: page(conn, "mastodon")

  defp page(conn, name) do
    locale = locale(conn)

    case AgentDocs.negotiate(conn, [:md]) do
      :md ->
        conn
        |> put_resp_content_type("text/markdown")
        |> put_private(:vutuv_agent_doc_sent, true)
        |> send_resp(200, fill_host(@sources[name][locale]))
        |> halt()

      :html ->
        conn
        |> AgentDocs.put_html_alternates([:md])
        |> render("markdown.html",
          page_title: @titles[name][locale],
          contents: @contents[name][locale],
          body: fill_host(@bodies[name][locale])
        )
    end
  end

  defp fill_host(text), do: String.replace(text, "{{host}}", Endpoint.host())

  # An installation may run locales this page has not been written in yet, so
  # fall back rather than crash on a missing file.
  defp locale(_conn) do
    locale = Gettext.get_locale(VutuvWeb.Gettext)
    if locale in @locales, do: locale, else: @default_locale
  end
end
