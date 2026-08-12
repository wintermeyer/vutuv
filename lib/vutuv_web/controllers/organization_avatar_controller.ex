defmodule VutuvWeb.OrganizationAvatarController do
  @moduledoc """
  `GET /organizations/:slug/avatar.jpg` — a page's logo as a square JPEG, the
  `icon` of its ActivityPub actor document.

  Issue #1334 shipped the page actor with no icon at all, so a page federated
  faceless however good its logo was, and no upload could change that. The
  member endpoint beside this one (`VutuvWeb.AvatarController`) had already
  answered the same question for `og:image`: whoever fetches an avatar from
  outside does it anonymously and does not decode the AVIF versions the site
  serves itself, so the JPEG is derived on the fly from the kept private
  original. A page's own `og:image` still falls back to the brand card
  (`VutuvWeb.OpenGraph` has no organization branch); when it grows one, this is
  the URL it should name.

  A page that is not public yet keeps its logo private, the same gate
  `VutuvWeb.OrganizationImageController` puts in front of every other byte of
  it. Served outside the browser pipeline like the feeds, with plain-text 404s:
  an unknown slug, a page with no logo and a page nobody may see all look the
  same from outside.
  """

  use VutuvWeb, :controller

  alias Vutuv.OrganizationImageStore
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization

  def show(conn, %{"slug" => slug}) do
    with %Organization{logo: logo} = organization when is_binary(logo) <-
           Organizations.get_organization_by_slug(slug),
         true <- Organizations.organization_visible_to?(organization, nil),
         {:ok, jpeg} <- OrganizationImageStore.og_jpeg(logo) do
      conn
      |> put_resp_content_type("image/jpeg", nil)
      |> put_resp_header("cache-control", "public, max-age=86400")
      |> send_resp(200, jpeg)
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not Found")
    end
  end
end
