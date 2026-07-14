defmodule VutuvWeb.SavedSearchToken do
  @moduledoc """
  The signed capability behind the alert mail's per-search "switch this alert
  off" link (issue #935). A token names a single `saved_searches` id and nothing
  else, so the long lifetime is safe (links in old mail must keep working) and
  possessing one can only ever set that one search's cadence to `none` — never
  touch another member's data.

  The member-level "switch off *all* saved-search alert mail" one-click lives in
  the same mail's `List-Unsubscribe` header and footer, handled by
  `VutuvWeb.UnsubscribeToken` (the `saved_search_emails?` preference). This token
  is the finer, per-search control.
  """

  alias Vutuv.SavedSearches.SavedSearch

  @salt "saved-search-disable"
  @max_age 60 * 60 * 24 * 365

  @doc "Signs a token that switches off alerts for one saved search."
  def sign(%SavedSearch{id: id}), do: Phoenix.Token.sign(VutuvWeb.Endpoint, @salt, id)

  @doc "Verifies a token. Returns `{:ok, saved_search_id}` or `{:error, reason}`."
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(VutuvWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, id} when is_binary(id) -> {:ok, id}
      {:ok, _other} -> {:error, :invalid}
      error -> error
    end
  end

  def verify(_token), do: {:error, :invalid}

  @doc "The absolute URL that switches off alerts for one saved search."
  def url(%SavedSearch{} = saved_search),
    do: public_url() <> "unsubscribe/search/" <> sign(saved_search)

  defp public_url, do: Application.get_env(:vutuv, VutuvWeb.Endpoint)[:public_url]
end
