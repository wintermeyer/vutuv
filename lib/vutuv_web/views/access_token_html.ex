defmodule VutuvWeb.AccessTokenHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/access_token/*")

  def expiry_line(%{expires_at: nil}), do: gettext("never expires")

  def expiry_line(%{expires_at: expires_at}),
    do: gettext("expires %{date}", date: Vutuv.ViewerClock.format(expires_at, :date))

  def last_used_line(%{last_used_at: nil}), do: gettext("never used")

  def last_used_line(%{last_used_at: last_used_at}),
    do: gettext("last used %{date}", date: Vutuv.ViewerClock.format(last_used_at, :date))
end
