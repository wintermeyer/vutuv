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
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Avatar
  alias Vutuv.Repo
  alias VutuvWeb.ControllerHelpers

  def show(conn, %{"slug" => slug}) do
    bytes =
      with %User{email_confirmed?: true, avatar: avatar} = user when not is_nil(avatar) <-
             Repo.get_by(User, username: slug) do
        Avatar.og_jpeg(user)
      end

    ControllerHelpers.send_og_jpeg(conn, bytes)
  end
end
