defmodule VutuvWeb.MastodonApi.ProfileController do
  @moduledoc """
  Editing your own account, and reporting somebody else's.

  **Only the two fields Mastodon's editor really maps.** `display_name` is a
  member's name and `note` is the profile headline; everything else a client
  offers on that screen — the avatar, the header image, the metadata rows, the
  bot and locked flags — either does not exist here or is not a single writable
  field, and writing part of a form while silently dropping the rest is worse
  than not offering it. A member's name is split into first and last on vutuv,
  so an incoming `display_name` is split on the last space, which is the same
  rule the sign-up form applies.

  Reporting goes through `Vutuv.Moderation.report_content/3` unchanged, so a
  report from a phone opens exactly the case a report from the website does —
  including the freezer, the strike rules and the reporter-visibility gate.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Moderation
  alias Vutuv.Moderation.Report
  alias Vutuv.Posts
  alias Vutuv.UUIDv7

  def update_credentials(conn, params) do
    user = conn.assigns.current_user

    case Accounts.update_user(user, profile_attrs(params)) do
      {:ok, updated} ->
        json(conn, Presenter.account(updated))

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "Validation failed: " <> changeset_error(changeset)})
    end
  end

  @doc """
  Files a report. `status_ids[]` reports one of the member's statuses, otherwise
  the whole profile is reported — which is the same pair of targets the website
  offers.
  """
  def create(conn, params) do
    reporter = conn.assigns.current_user

    with {:ok, target} <- report_target(conn, params),
         {:ok, _case} <-
           Moderation.report_content(reporter, target, %{
             "category" => category(params["category"]),
             "note" => params["comment"]
           }) do
      json(conn, %{
        id: nil,
        action_taken: false,
        category: category(params["category"]),
        comment: params["comment"] || ""
      })
    else
      {:error, :own_content} ->
        error(conn, 422, "You cannot report your own content.")

      {:error, :already_reported} ->
        error(conn, 422, "You have already reported this.")

      {:error, :not_allowed} ->
        error(conn, 404, "Record not found")

      {:error, :not_found} ->
        error(conn, 404, "Record not found")

      {:error, _changeset} ->
        error(conn, 422, "The report could not be filed.")
    end
  end

  # A status id wins over the account id: reporting a specific post is the more
  # precise complaint, and it is what a client sends when the member tapped a
  # post rather than a profile.
  defp report_target(conn, %{"status_ids" => [id | _rest]}), do: reported_status(conn, id)

  defp report_target(conn, %{"status_ids" => id}) when is_binary(id),
    do: reported_status(conn, id)

  defp report_target(_conn, %{"account_id" => id}) do
    case UUIDv7.with_cast(id, &Accounts.get_user/1) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  end

  defp report_target(_conn, _params), do: {:error, :not_found}

  defp reported_status(conn, id) do
    viewer = conn.assigns.current_user

    case Posts.get_post(id) do
      nil -> {:error, :not_found}
      post -> if Posts.visible_to?(post, viewer), do: {:ok, post}, else: {:error, :not_allowed}
    end
  end

  defp category(value) do
    if value in Report.categories(), do: value, else: hd(Report.categories())
  end

  # vutuv keeps a first and a last name; Mastodon sends one string. The last
  # space is the split, so "Anna Maria Meier" keeps the given names together.
  defp profile_attrs(params) do
    %{}
    |> put_name(params["display_name"])
    |> put_headline(params["note"])
  end

  defp put_name(attrs, value) when is_binary(value) do
    case value |> String.trim() |> String.split(" ") do
      [""] ->
        attrs

      [only] ->
        Map.put(attrs, "first_name", only)

      parts ->
        Map.merge(attrs, %{
          "first_name" => Enum.join(Enum.drop(parts, -1), " "),
          "last_name" => List.last(parts)
        })
    end
  end

  defp put_name(attrs, _absent), do: attrs

  defp put_headline(attrs, value) when is_binary(value), do: Map.put(attrs, "headline", value)
  defp put_headline(attrs, _absent), do: attrs

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end
end
