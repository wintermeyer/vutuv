defmodule VutuvWeb.Home do
  @moduledoc """
  Where a signed-in member's "home" is.

  The newsfeed (`/feed`) is only worth landing on once the member follows at
  least one other account; until then (most importantly right after sign-up,
  when the feed would be empty) home is their own profile, where they can fill
  it in and find people to follow. Login, the logged-out-only guard
  (`VutuvWeb.Plug.RequireUserLoggedOut`) and the shell logo all resolve home
  through here so the rule lives in exactly one place.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico robots.txt)

  alias Vutuv.Accounts.User
  alias Vutuv.Social

  @doc """
  The home path for `user`: `/feed` once they follow at least one account
  (`Vutuv.Social.follows_anyone?/1`), otherwise their own profile.
  """
  def path(%User{} = user) do
    if Social.follows_anyone?(user), do: ~p"/feed", else: ~p"/#{user}"
  end
end
