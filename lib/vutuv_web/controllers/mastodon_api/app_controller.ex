defmodule VutuvWeb.MastodonApi.AppController do
  @moduledoc "Mastodon's public, unattended OAuth application registration."

  use VutuvWeb, :controller

  alias Ecto.Changeset
  alias Vutuv.ApiAuth
  alias Vutuv.MastodonApi.Scopes
  alias VutuvWeb.RateLimit

  @registration_limit 20
  @registration_window :timer.hours(1)

  def create(conn, params) do
    with :ok <- registration_allowed?(conn),
         {:ok, scopes} <- Scopes.parse_registration(params["scopes"]),
         attrs <- app_attrs(params, scopes),
         {:ok, app, secret} <- ApiAuth.create_mastodon_app(attrs) do
      json(conn, credential_application(app, secret))
    else
      {:error, :rate_limited} ->
        conn |> put_status(429) |> json(%{error: "Too many application registrations"})

      {:error, :invalid_scope} ->
        validation_error(conn, "Scopes are invalid.")

      {:error, changeset} ->
        validation_error(conn, changeset_error(changeset))
    end
  end

  defp registration_allowed?(conn) do
    case RateLimit.check(conn, :mastodon_app_registration, nil,
           limit: @registration_limit,
           window_ms: @registration_window
         ) do
      :ok -> :ok
      :rate_limited -> {:error, :rate_limited}
    end
  end

  defp app_attrs(params, scopes) do
    %{
      "name" => params["client_name"],
      "homepage_url" => params["website"],
      "redirect_uris" => normalize_redirect_uris(params["redirect_uris"]),
      "registered_scopes" => scopes
    }
  end

  defp normalize_redirect_uris(uris) when is_list(uris), do: uris

  defp normalize_redirect_uris(uris) when is_binary(uris) do
    String.split(uris, ~r/\R/, trim: true)
  end

  defp normalize_redirect_uris(_missing), do: []

  defp credential_application(app, secret) do
    %{
      id: app.id,
      name: app.name,
      website: app.homepage_url,
      scopes: app.registered_scopes,
      redirect_uri: Enum.join(app.redirect_uris, "\n"),
      redirect_uris: app.redirect_uris,
      client_id: app.client_id,
      client_secret: secret,
      client_secret_expires_at: 0
    }
  end

  defp validation_error(conn, message) do
    conn |> put_status(422) |> json(%{error: "Validation failed: " <> message})
  end

  defp changeset_error(changeset) do
    changeset
    |> Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end
end
