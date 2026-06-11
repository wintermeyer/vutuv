defmodule VutuvWeb.AccessTokenHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/access_token/*")

  def expiry_line(%{expires_at: nil}), do: gettext("never expires")

  def expiry_line(%{expires_at: expires_at}),
    do: gettext("expires %{date}", date: Calendar.strftime(expires_at, "%Y-%m-%d"))

  def last_used_line(%{last_used_at: nil}), do: gettext("never used")

  def last_used_line(%{last_used_at: last_used_at}),
    do: gettext("last used %{date}", date: Calendar.strftime(last_used_at, "%Y-%m-%d"))
end
