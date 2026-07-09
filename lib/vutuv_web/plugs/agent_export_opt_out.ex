defmodule VutuvWeb.Plug.AgentExportOptOut do
  @moduledoc """
  Refuses the agent-document formats of a member who fully opted out of
  machine use (`VutuvWeb.ContentPolicy.agent_docs_blocked?/1`: both
  `noindex?` and `noai?` set): a `.md`/`.txt`/`.json`/`.xml` request for
  their profile, section pages or people lists answers the plain 404, and
  the `Accept`-negotiated twins are refused the same way. The `.vcf` vCard
  deliberately stays — a contact-exchange format for humans, not agent
  food. One opt-out alone blocks nothing; those documents keep flowing
  with the member's choice embedded (headers, JSON/XML fields, Markdown
  frontmatter, text footer).

  Runs after `EnsureActivated` (it needs the resolved `:user`) in the
  `:user_pipe` and on `UserController.show`, so the whole `/:slug`
  namespace shares the one gate. HTML requests pass through but are marked
  (`:vutuv_agent_docs_blocked`), which makes
  `VutuvWeb.AgentDocs.put_html_alternates/2` skip the `<link
  rel="alternate">` head tags and the `Link` header alternates — the page
  never advertises URLs that 404. The member's published posts (and their
  RSS feed) are deliberately out of scope: this gate is about the profile.
  """

  import Plug.Conn

  alias Vutuv.Accounts.User
  alias VutuvWeb.Plug.AgentFormat

  # Every agent format except :vcf.
  @blocked_formats [:md, :txt, :json, :xml]

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:user] do
      %User{} = user ->
        if VutuvWeb.ContentPolicy.agent_docs_blocked?(user) do
          refuse_or_mark(conn)
        else
          conn
        end

      _missing ->
        conn
    end
  end

  defp refuse_or_mark(conn) do
    conn = put_private(conn, :vutuv_agent_docs_blocked, true)

    format = AgentFormat.requested_format(conn)

    if format in @blocked_formats do
      VutuvWeb.ControllerHelpers.render_error(conn, 404)
    else
      conn
    end
  end
end
