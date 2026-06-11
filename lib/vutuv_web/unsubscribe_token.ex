defmodule VutuvWeb.UnsubscribeToken do
  @moduledoc """
  The signed capability behind "switch notification emails off without a
  login": every notification email carries it in its `List-Unsubscribe`
  header (RFC 8058 one-click) and as a footer link.

  The token only names the user id, and possessing it only authorizes
  flipping `notification_emails?` off — nothing else — so the long lifetime
  is safe: unsubscribe links in old mail must keep working.
  """

  @salt "unsubscribe"
  @max_age 60 * 60 * 24 * 365

  def sign(%Vutuv.Accounts.User{id: id}),
    do: Phoenix.Token.sign(VutuvWeb.Endpoint, @salt, id)

  def verify(token) when is_binary(token),
    do: Phoenix.Token.verify(VutuvWeb.Endpoint, @salt, token, max_age: @max_age)

  def verify(_token), do: {:error, :invalid}

  @doc "The absolute unsubscribe URL an email carries (header and footer)."
  def url(%Vutuv.Accounts.User{} = user) do
    public_url = Application.get_env(:vutuv, VutuvWeb.Endpoint)[:public_url]
    public_url <> "unsubscribe/" <> sign(user)
  end
end
