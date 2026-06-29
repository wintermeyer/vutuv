defmodule Vutuv.Newsletters.NewsletterClick do
  @moduledoc """
  One recorded click on a vutuv.de link carried in a newsletter: which member
  followed which link, and when.

  Newsletter HTML mail rewrites every internal link so its `href` carries a
  signed per-recipient token (`?nlt=...`, `VutuvWeb.NewsletterToken`). When the
  recipient follows it, `VutuvWeb.Plug.NewsletterClick` verifies the token and
  writes a row here (the `url` with the tracking param stripped), then redirects
  to the clean URL. Rows are written directly (not cast); `inserted_at` is the
  "when". There is one row per click event, so a member who clicks twice is two
  rows — the success overview derives unique clickers and per-link tallies from
  them. The plain-text body keeps the bare link, so this only captures HTML
  clicks.
  """

  use VutuvWeb, :model

  alias Vutuv.Newsletters.Newsletter

  schema "newsletter_clicks" do
    field(:url, :string)

    belongs_to(:newsletter, Newsletter)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps(updated_at: false)
  end
end
