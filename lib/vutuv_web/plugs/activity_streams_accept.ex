defmodule VutuvWeb.Plug.ActivityStreamsAccept do
  @moduledoc """
  Reads the JSON-LD spelling of an ActivityPub fetch as the one the `:browser`
  pipeline admits.

  ActivityPub §3.2 names two `Accept` values a server must answer with the
  object: `application/activity+json` and `application/ld+json;
  profile="https://www.w3.org/ns/activitystreams"`. Only the first is on the
  pipeline's accept list, so the second is rewritten to it before `accepts`
  runs, and takes the same path from there, including `VutuvWeb.Plug.HtmlOnly`'s
  406 on pages with no ActivityPub form. A bare `application/ld+json` counts
  too, as in `VutuvWeb.FediverseController.ap_request?/1`; a header that also
  names `text/html` is a browser and is left alone.

  Adding a format to `accepts` instead would not do: `:mime` already maps
  `application/ld+json` to `jsonld`, and every controller page of the pipeline
  would then be asked to render that format.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    accept = conn |> get_req_header("accept") |> Enum.join(",") |> String.downcase()

    if accept =~ "application/ld+json" and not (accept =~ "text/html") do
      put_req_header(conn, "accept", "application/activity+json")
    else
      conn
    end
  end
end
