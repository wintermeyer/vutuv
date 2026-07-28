defmodule VutuvWeb.AuthorizeInteractionController do
  @moduledoc """
  `GET /authorize_interaction?uri=…` — the door the rest of the Fediverse sends
  a member of *this* installation through when they want to act on an account
  somewhere else.

  It is the mirror image of `VutuvWeb.RemoteFollowController`: there a visitor
  from another network follows a member here from their own server; here a
  member here follows an account out there from that account's server. The
  other server starts it. Press Follow on Mastodon while signed out, type
  `@member@vutuv.de`, and that server reads our WebFinger document, takes the
  `http://ostatus.org/schema/1.0/subscribe` template out of it (see
  `VutuvWeb.FediverseController`) and sends the visitor here with the account
  they were looking at in `uri`.

  **The path is not ours to choose.** Mastodon falls back to
  `https://<host>/authorize_interaction?uri={uri}` whenever a WebFinger
  document names no template, so this word is spent whether we advertise it or
  not — which is why it is a root route with a `Vutuv.Accounts.ReservedSlugs`
  entry rather than living under `/system/` like a page of our own design.

  **It follows nothing.** The arrival is a `GET` from another site, so acting on
  it would let any page on the web make a signed-in member send a signed Follow
  to a server of its choosing simply by linking here. Instead the address is
  resolved (pure string work, no network) and handed to the follow box on
  `/settings/fediverse/following`, where the member sees what they are about to
  do and presses the button themselves — the same reason that page prefills
  rather than acts on its own `?address=`.
  """

  use VutuvWeb, :controller

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteFollow
  alias VutuvWeb.ControllerHelpers

  def show(conn, params) do
    cond do
      not Fediverse.enabled?() ->
        ControllerHelpers.render_error(conn, 404)

      is_nil(conn.assigns[:current_user]) ->
        # The same marker the OAuth consent screen sets, so the login survives
        # the PIN round trip and lands back on this URL with the address still
        # in it.
        conn
        |> put_session(:login_return_to, current_path(conn))
        |> put_flash(
          :info,
          gettext(
            "Please sign in first, then you can follow that account from your vutuv account."
          )
        )
        |> redirect(to: ~p"/login")

      true ->
        hand_over(conn, params["uri"] || params["acct"])
    end
  end

  defp hand_over(conn, uri) do
    case interaction(uri) do
      {:ok, :account, address} ->
        redirect(conn, to: ~p"/settings/fediverse/following?#{[address: address]}")

      {:ok, :post, address} ->
        conn
        |> put_flash(:info, post_link_message(address))
        |> redirect(to: ~p"/settings/fediverse/following?#{[address: address]}")

      :error ->
        conn
        |> put_flash(:error, gettext("That link did not name a Fediverse account we can read."))
        |> redirect(to: ~p"/settings/fediverse/following")
    end
  end

  # Every spelling of `{uri}` in the wild: the profile URL Mastodon fills in,
  # the `acct:` URI older implementations send, and the plain handle. Parsed by
  # `Vutuv.Fediverse.RemoteFollow`, so what counts as an address here is what
  # counts as one in the follow box the member lands in.
  defp interaction(uri) when is_binary(uri) do
    uri = uri |> String.trim() |> String.replace_prefix("acct:", "")

    case RemoteFollow.parse_address(uri) do
      {:ok, {user, host}} -> {:ok, :account, "@#{user}@#{host}"}
      {:error, _reason} -> author_of_post(uri)
    end
  end

  defp interaction(_uri), do: :error

  # A link to a single post rather than to an account: the other network sends
  # those here too, for a reply or a boost. Neither is something vutuv can
  # start from outside, so we read the author out of the URL and offer the one
  # thing that does work — following them — saying so rather than answering a
  # link we understood with an error.
  #
  # The author's own URL is rebuilt and handed back to `parse_address/1`, so
  # the handle and host are validated by the one parser instead of a second
  # copy of its rules living here.
  defp author_of_post(url) do
    with %URI{host: host, path: path} when is_binary(host) and is_binary(path) <- URI.parse(url),
         {:ok, author_url} <- author_url(host, String.split(path, "/", trim: true)),
         {:ok, {user, author_host}} <- RemoteFollow.parse_address(author_url) do
      {:ok, :post, "@#{user}@#{author_host}"}
    else
      _not_a_post -> :error
    end
  end

  defp author_url(host, ["@" <> user, _id]), do: {:ok, "https://#{host}/@#{user}"}

  defp author_url(host, ["users", user, "statuses", _id]),
    do: {:ok, "https://#{host}/users/#{user}"}

  defp author_url(_host, _segments), do: :error

  defp post_link_message(address) do
    gettext(
      "That link points at a single post. You can follow its author, %{account}, from here.",
      account: address
    )
  end
end
