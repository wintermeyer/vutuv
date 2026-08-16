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
  alias VutuvWeb.ControllerHelpers

  def show(conn, %{"slug" => slug}) do
    bytes =
      with %Organization{logo: logo} = organization when is_binary(logo) <-
             Organizations.get_organization_by_slug(slug),
           true <- Organizations.organization_visible_to?(organization, nil) do
        OrganizationImageStore.og_jpeg(logo)
      end

    ControllerHelpers.send_og_jpeg(conn, bytes)
  end
end
