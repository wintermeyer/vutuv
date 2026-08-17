defmodule VutuvWeb.MastodonApi.PushController do
  @moduledoc """
  Web Push subscriptions: the endpoint a client registers so the phone is woken
  instead of polling.

  Keyed on the access token, so one device is one subscription and revoking the
  app takes it with it. The `server_key` a client needs to build the browser
  subscription is this installation's VAPID public key; where an operator has
  configured none, every call here answers 403 rather than accepting a
  subscription that could never be delivered to.
  """

  use VutuvWeb, :controller

  import Ecto.Query, only: [where: 3]

  alias Vutuv.MastodonApi.PushSubscription
  alias Vutuv.MastodonApi.WebPush
  alias Vutuv.Repo

  def create(conn, params) do
    with :ok <- push_available(),
         {:ok, attrs} <- subscription_attrs(params) do
      token = conn.assigns.api_token

      %PushSubscription{user_id: conn.assigns.current_user.id, api_token_id: token.id}
      |> PushSubscription.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:endpoint, :p256dh, :auth, :alerts, :updated_at]},
        conflict_target: :api_token_id
      )
      |> case do
        {:ok, subscription} -> json(conn, subscription_json(subscription))
        {:error, changeset} -> validation_error(conn, changeset)
      end
    else
      {:error, :not_configured} -> error(conn, 403, "Push is not configured on this server")
      {:error, :invalid} -> error(conn, 422, "Validation failed: subscription is incomplete")
    end
  end

  def show(conn, _params) do
    case current(conn) do
      nil -> error(conn, 404, "Record not found")
      subscription -> json(conn, subscription_json(subscription))
    end
  end

  def update(conn, params) do
    case current(conn) do
      nil ->
        error(conn, 404, "Record not found")

      subscription ->
        subscription
        |> PushSubscription.changeset(%{"alerts" => params["data"]["alerts"] || params["alerts"]})
        |> Repo.update()
        |> case do
          {:ok, updated} -> json(conn, subscription_json(updated))
          {:error, changeset} -> validation_error(conn, changeset)
        end
    end
  end

  def delete(conn, _params) do
    case current(conn) do
      nil -> json(conn, %{})
      subscription -> Repo.delete(subscription) && json(conn, %{})
    end
  end

  defp current(conn) do
    token_id = conn.assigns.api_token.id

    PushSubscription
    |> where([s], s.api_token_id == ^token_id)
    |> Repo.one()
  end

  defp push_available do
    if WebPush.configured?(), do: :ok, else: {:error, :not_configured}
  end

  # Mastodon nests the browser's own PushSubscription under `subscription`, and
  # the alert preferences under `data`.
  defp subscription_attrs(%{"subscription" => %{"endpoint" => endpoint, "keys" => keys}} = params)
       when is_binary(endpoint) and is_map(keys) do
    {:ok,
     %{
       "endpoint" => endpoint,
       "p256dh" => keys["p256dh"],
       "auth" => keys["auth"],
       "alerts" => params["data"]["alerts"] || %{}
     }}
  end

  defp subscription_attrs(_params), do: {:error, :invalid}

  defp subscription_json(%PushSubscription{} = subscription) do
    %{
      id: subscription.id,
      endpoint: subscription.endpoint,
      alerts: subscription.alerts,
      server_key: WebPush.public_key(),
      policy: "all"
    }
  end

  defp validation_error(conn, changeset) do
    detail =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
      |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
      |> Enum.join(", ")

    error(conn, 422, "Validation failed: " <> detail)
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
