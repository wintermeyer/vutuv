defmodule VutuvWeb.PushDeviceController do
  @moduledoc """
  The browsers a member asked to be woken on when vutuv is closed (issue
  #1729).

  A device registers itself: `assets/js/app.js` asks the service worker's
  `PushManager` for a subscription and posts the three values it hands back.
  There is nothing to render for that, so `create/2` and `delete/2` answer
  JSON to the page's own fetch; `forget/2` is the settings list's row button
  and answers the way every other row action there does, with a redirect.

  `delete/2` is what a **sign-out** calls, and it is deliberately not scoped to
  the signed-in member: it names one endpoint, which is one browser, and the
  browser saying "stop pushing to me" is the authority on that whether or not
  a session is still standing. Nothing here is readable, so a guessed endpoint
  discloses nothing — it only stops a push somebody would have to know the
  endpoint to stop.
  """

  use VutuvWeb, :controller

  alias Vutuv.Sessions
  alias Vutuv.WebPush
  alias Vutuv.WebPush.Subscriptions

  @doc "Registers this browser. The body is a `PushSubscription`'s own JSON."
  def create(conn, params) do
    user_id = conn.assigns.current_user_id

    with true <- WebPush.enabled?(),
         {:ok, attrs} <- subscription_attrs(params),
         {:ok, _subscription} <- Subscriptions.subscribe(user_id, attrs, device(conn)) do
      json(conn, %{ok: true})
    else
      # An intranet installation that reaches no push service says so, rather
      # than storing a subscription nothing will ever be sent to.
      false ->
        conn |> put_status(:forbidden) |> json(%{ok: false, error: "disabled"})

      _invalid ->
        conn |> put_status(:unprocessable_entity) |> json(%{ok: false, error: "invalid"})
    end
  end

  @doc "Forgets this browser, by the endpoint it names."
  def delete(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) do
    :ok = Subscriptions.unsubscribe(endpoint)
    json(conn, %{ok: true})
  end

  def delete(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{ok: false, error: "invalid"})

  @doc "The settings list's row button: forget one of my own devices."
  def forget(conn, %{"id" => id}) do
    :ok = Subscriptions.delete(conn.assigns.current_user_id, id)

    conn
    |> put_flash(:info, gettext("This device will no longer be notified."))
    |> redirect(to: ~p"/settings/notifications")
  end

  # A browser's `PushSubscription.toJSON()`, which is what the page posts
  # verbatim rather than picking apart in JS — one shape, defined by the web
  # platform, and nothing to keep in step on two sides.
  defp subscription_attrs(%{"endpoint" => endpoint, "keys" => %{} = keys})
       when is_binary(endpoint) do
    {:ok, %{"endpoint" => endpoint, "p256dh" => keys["p256dh"], "auth" => keys["auth"]}}
  end

  defp subscription_attrs(_params), do: :error

  # The same label the device list under Sign-in & security shows, so one phone
  # is called one thing across the site.
  defp device(conn) do
    conn
    |> get_req_header("user-agent")
    |> List.first()
    |> Sessions.device_summary()
  end
end
