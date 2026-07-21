defmodule VutuvWeb.Admin.UserPrefController do
  @moduledoc """
  Per-member preference overrides, for support: an admin sets or clears any
  `Vutuv.Prefs` value of one member (e.g. to reproduce or fix a "my feed
  looks wrong" report). A cleared field goes back to nil = "inherit the
  installation default", exactly as if the member had never touched it; a set
  value is indistinguishable from one the member chose on /settings — it uses
  the same columns, so the member can change or reset it themselves at any
  time. The form is generated from the registry, like the defaults page.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Prefs
  alias VutuvWeb.ControllerHelpers

  def show(conn, %{"id" => id}) do
    with_member(conn, id, fn member -> render_show(conn, member, %{}, []) end)
  end

  def update(conn, %{"id" => id, "prefs" => params}) do
    with_member(conn, id, fn member ->
      case Prefs.admin_update_user(member, params) do
        {:ok, member} ->
          conn
          |> put_flash(
            :info,
            gettext("The preferences of %{name} have been saved.", name: "@#{member.username}")
          )
          |> redirect(to: ~p"/admin/users/#{member.id}/preferences")

        {:error, invalid} when is_list(invalid) ->
          conn
          |> put_status(422)
          |> put_flash(:error, gettext("Please check the fields marked in red."))
          |> render_show(member, params, invalid)

        {:error, _changeset} ->
          conn
          |> put_status(422)
          |> put_flash(:error, gettext("Please check the fields marked in red."))
          |> render_show(member, params, [])
      end
    end)
  end

  # The controls show the member's explicit value, or blank = "inherit"; on a
  # failed save the submitted raw values, so the admin can correct in place.
  # The inherit option labels carry the current installation defaults read
  # from the DB (the admin-facing truth, like the defaults page).
  defp render_show(conn, member, raw_params, invalid) do
    values =
      Map.new(Prefs.registry(), fn pref ->
        raw =
          Map.get(raw_params, Atom.to_string(pref.key)) ||
            case Map.fetch!(member, pref.key) do
              nil -> ""
              value -> Prefs.dump(pref, value)
            end

        {pref.key, raw}
      end)

    render(conn, "show.html",
      member: member,
      values: values,
      invalid: invalid,
      defaults: Prefs.load_installation_defaults(),
      page_title: gettext("Preferences of %{name}", name: "@#{member.username}")
    )
  end

  defp with_member(conn, id, fun) do
    case ControllerHelpers.get_user(id) do
      %User{} = member -> fun.(member)
      nil -> ControllerHelpers.render_error(conn, 404)
    end
  end
end
