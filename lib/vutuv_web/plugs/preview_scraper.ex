defmodule VutuvWeb.Plug.PreviewScraper do
  @moduledoc """
  Names the one link-preview scraper whose feed wants a different picture, as
  the assign `:square_preview?` that `VutuvWeb.OpenGraph` reads.

  LinkedIn's organic feed has drawn every shared link as a small square cut
  from the middle of the `og:image` since 2024, whatever the image's size —
  the wide card every other platform draws large is a strip of headline to
  it. So its scraper (`LinkedInBot`) is told a square picture where the page
  has one (the author's face, or a square post card), and every other reader
  of the same URL gets the wide card.

  A page that answers differently by user agent has to say so, or a shared
  cache hands X the LinkedIn tag set: `Vary: User-Agent` goes on every HTML
  response this pipeline serves, whatever the agent, because the header
  describes the URL, not the one response. Read from the request here rather
  than inside the tag builder, the way `VutuvWeb.Plug.AgentFormat` settles
  the format and `VutuvWeb.Plug.Locale` the language before any controller
  runs, so `OpenGraph` stays a pure function of the assigns.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> assign(:square_preview?, square_preview?(conn))
    # At send time, not now: the agent-format answers write their own Vary
    # (`accept`, `accept-language`) when they respond, which would replace one
    # set here. Merging as the response leaves keeps both.
    |> register_before_send(&merge_vary(&1, "user-agent"))
  end

  @doc "Whether this request comes from LinkedIn's link-preview scraper."
  def square_preview?(%Plug.Conn{} = conn) do
    conn
    |> get_req_header("user-agent")
    |> Enum.any?(&String.contains?(&1, "LinkedInBot"))
  end

  # Adds a name to the Vary header of an HTML response without dropping one
  # another plug set. Only HTML: the agent-format siblings (`.md`, `.json`, …)
  # carry no preview tags and answer every agent alike.
  defp merge_vary(conn, name) do
    case {html?(conn), get_resp_header(conn, "vary")} do
      {false, _vary} -> conn
      {true, []} -> put_resp_header(conn, "vary", name)
      {true, [existing | _]} -> put_resp_header(conn, "vary", existing <> ", " <> name)
    end
  end

  defp html?(conn) do
    Enum.any?(get_resp_header(conn, "content-type"), &String.starts_with?(&1, "text/html"))
  end
end
