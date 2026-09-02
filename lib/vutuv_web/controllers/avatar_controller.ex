defmodule VutuvWeb.AvatarController do
  @moduledoc """
  `GET /:slug/avatar.jpg` — the member's avatar as a square JPEG, the
  image behind `og:image` on their pages (`VutuvWeb.OpenGraph`). Link
  preview scrapers (WhatsApp, Facebook, …) don't decode the AVIF versions
  the site serves itself, so this derives a JPEG on the fly from the kept
  private original (metadata-stripped, see `Vutuv.Avatar.og_jpeg/1`).

  Served outside the browser pipeline like the feeds, with plain-text
  404s: unknown slugs, unactivated members and members without an avatar
  all look the same. The public cache lifetime keeps repeat scraper
  traffic off libvips.

  A member the site withholds keeps their picture withheld too. `email_confirmed?`
  alone let this endpoint answer for a suspended, frozen or deactivated account
  whose every other page is a 404 or a 410 — and it answers **anonymously**, so
  the face stayed readable by anybody who knew the handle. The gate is now the
  one the rest of the slug space uses, asked with no viewer, exactly as
  `VutuvWeb.OrganizationAvatarController` asks it for a page.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Avatar
  alias Vutuv.Moderation
  alias Vutuv.Repo
  alias VutuvWeb.ControllerHelpers

  def show(conn, %{"slug" => slug}) do
    bytes =
      with %User{avatar: avatar} = user when not is_nil(avatar) <-
             Repo.get_by(User, username: slug),
           true <- Moderation.profile_visible_to?(user, nil) do
        Avatar.og_jpeg(user)
      end

    ControllerHelpers.send_og_jpeg(conn, bytes)
  end
end
