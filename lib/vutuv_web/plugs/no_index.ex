defmodule VutuvWeb.Plug.NoIndex do
  @moduledoc """
  Stamps the page-level robots opt-out (`X-Robots-Tag: noindex, noai,
  noimageai`) on the response.

  Used by the `:user_pipe` pipeline for the per-user profile detail pages
  (phone numbers, emails, addresses, links, social media, work history, …),
  which are publicly readable but expose personal data that should never
  surface in search results or AI corpora — a page-level restriction covers
  both axes, matching the pages' agent-doc siblings (`SectionDocs`,
  `ListDocs`). The public profile page itself is not routed through this
  plug and carries only the member's own opt-outs.

  robots.txt only *asks* crawlers not to fetch a URL; a disallowed URL can
  still be indexed (as a bare link) if referenced elsewhere. This header
  closes that gap by telling compliant crawlers not to index the page even
  when they do fetch it.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    VutuvWeb.ContentPolicy.put_robots_header(conn, true, true)
  end
end
