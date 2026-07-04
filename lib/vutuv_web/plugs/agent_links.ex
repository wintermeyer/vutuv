defmodule VutuvWeb.Plug.AgentLinks do
  @moduledoc """
  HTTP `Link` headers for HTML-free discovery (the agent-readiness spec's
  link-headers convention): every browser-pipeline response advertises
  /llms.txt (`describedby`) and the sitemap, and a page with agent-format
  siblings repeats its alternates in the header — built at send time from
  the same `:agent_doc_alternates` assign the root layout renders as
  `<link rel="alternate">` tags, so header and HTML cannot drift.

  Agent-document responses add their own `rel="canonical"` entry in
  `VutuvWeb.AgentDocs.send_doc/3`; this plug contributes the globals there
  too (the doc routes live in the browser pipeline).
  """

  @behaviour Plug

  import Plug.Conn

  @global ~s(</llms.txt>; rel="describedby"; type="text/markdown", ) <>
            ~s(</sitemap.xml>; rel="sitemap"; type="application/xml")

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # before_send, not inline: the alternates assign (and the feed entry)
    # is complete only once the controller has run.
    register_before_send(conn, &put_links/1)
  end

  defp put_links(conn) do
    alternates =
      for alt <- conn.assigns[:agent_doc_alternates] || [] do
        ~s(<#{alt.href}>; rel="alternate"; type="#{alt.type}")
      end

    prepend_resp_headers(conn, [{"link", Enum.join([@global | alternates], ", ")}])
  end
end
