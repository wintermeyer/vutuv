defmodule VutuvWeb.NewsletterToken do
  @moduledoc """
  The signed capability behind newsletter click tracking: every vutuv.de link in
  a newsletter's HTML body carries one in a `?nlt=` query parameter, naming the
  newsletter and the recipient it was sent to (`VutuvWeb.Plug.NewsletterClick`
  records the click and redirects to the clean URL).

  A token names only the newsletter id and the recipient's user id, nothing
  else, so the long lifetime is safe: links live in inboxes for a long time and
  must keep recording. The token is unguessable and tamper-proof, so a recipient
  cannot forge clicks for another member, and the raw ids never appear in the
  URL. The destination is the page the link actually points at, so the token
  carries no URL.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Newsletters.Newsletter

  @salt "newsletter-click"
  @max_age 60 * 60 * 24 * 365

  @doc "The query-parameter name a tracked link carries."
  def param, do: "nlt"

  @doc "Signs a token naming the newsletter and the recipient."
  def sign(newsletter_id, user_id) when is_binary(newsletter_id) and is_binary(user_id),
    do: Phoenix.Token.sign(VutuvWeb.Endpoint, @salt, {newsletter_id, user_id})

  def sign(%Newsletter{id: newsletter_id}, %User{id: user_id}), do: sign(newsletter_id, user_id)

  @doc """
  Verifies a token. Returns `{:ok, newsletter_id, user_id}` or `:error`.
  """
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(VutuvWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, {newsletter_id, user_id}} when is_binary(newsletter_id) and is_binary(user_id) ->
        {:ok, newsletter_id, user_id}

      _ ->
        :error
    end
  end

  def verify(_token), do: :error
end
