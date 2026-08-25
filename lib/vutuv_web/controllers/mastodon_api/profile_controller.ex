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

  import VutuvWeb.MastodonApi.Errors

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Moderation
  alias Vutuv.Moderation.Report
  alias Vutuv.Posts.Post
  alias Vutuv.UUIDv7
  alias VutuvWeb.MastodonApi.Statuses

  def update_credentials(conn, params) do
    user = conn.assigns.current_user

    case Accounts.update_user(user, profile_attrs(params)) do
      {:ok, updated} ->
        json(conn, Presenter.account(updated))

      {:error, changeset} ->
        validation_error(conn, changeset)
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

      {:error, reason} when reason in [:not_allowed, :not_found] ->
        not_found(conn)

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

  # The same id grammar every other status reader uses (issue #1596): a client
  # reports the status it is looking at, and the timeline hands it ids like
  # `repost-<uuid>` and the `remote-` family, all of which `Posts.get_post/1`
  # alone answered with `:not_found`. A cached remote object stays unreportable
  # as it was — a report here opens a case against something published on this
  # installation, and that is what `Vutuv.Moderation` knows how to act on.
  defp reported_status(conn, id) do
    case Statuses.resolve(id) do
      %Post{} = post ->
        if Statuses.visible?(conn, post), do: {:ok, post}, else: {:error, :not_allowed}

      _no_local_post ->
        {:error, :not_found}
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
end
