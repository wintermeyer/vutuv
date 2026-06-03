defmodule VutuvWeb.Plug.NoIndex do
  @moduledoc """
  Stamps `X-Robots-Tag: noindex` on the response.

  Used by the `:user_pipe` pipeline for the per-user profile detail pages
  (phone numbers, emails, addresses, links, social media, work history, …),
  which are publicly readable but expose personal data that should never
  surface in search results. The public profile page itself is not routed
  through this plug and stays indexable.

  robots.txt only *asks* crawlers not to fetch a URL; a disallowed URL can
  still be indexed (as a bare link) if referenced elsewhere. This header
  closes that gap by telling compliant crawlers not to index the page even
  when they do fetch it.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    put_resp_header(conn, "x-robots-tag", "noindex")
  end
end
