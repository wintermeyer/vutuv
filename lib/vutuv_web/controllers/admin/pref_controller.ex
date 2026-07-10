defmodule VutuvWeb.Admin.PrefController do
  @moduledoc """
  The installation's preference defaults (`Vutuv.Prefs`): what every member
  who has not customized a setting — and every logged-out visitor — gets.

  The form is generated from the `Vutuv.Prefs.registry/0`, so a new
  preference shows up here without touching this controller. Saving reloads
  the defaults cache on every node; a member's own explicit choice always
  wins over these defaults. Per-member support overrides live on
  `VutuvWeb.Admin.UserPrefController`.
  """

  use VutuvWeb, :controller

  alias Vutuv.Prefs

  def index(conn, _params), do: render_index(conn, %{}, [])

  def update(conn, %{"prefs" => params}) do
    case Prefs.put_defaults(params) do
      {:ok, _defaults} ->
        conn
        |> put_flash(:info, gettext("The preference defaults have been saved."))
        |> redirect(to: ~p"/admin/preferences")

      {:error, invalid} ->
        conn
        |> put_status(422)
        |> put_flash(:error, gettext("Please check the fields marked in red."))
        |> render_index(params, invalid)
    end
  end

  # The controls show the DB truth (shipped defaults + stored override rows),
  # not the cache — and on a failed save the submitted raw values, so the
  # admin can correct instead of retyping.
  defp render_index(conn, raw_params, invalid) do
    rows = Prefs.list_default_rows()

    values =
      Map.new(Prefs.registry(), fn pref ->
        raw =
          Map.get(raw_params, Atom.to_string(pref.key)) ||
            Map.get(rows, pref.key) ||
            Prefs.dump(pref, pref.default)

        {pref.key, raw}
      end)

    render(conn, "index.html",
      values: values,
      invalid: invalid,
      overridden: Map.keys(rows),
      counts: Prefs.customized_counts(),
      page_title: gettext("Preference defaults")
    )
  end
end
