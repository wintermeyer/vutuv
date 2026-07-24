defmodule VutuvWeb.Admin.AccountController do
  @moduledoc """
  The admin account freezer (issue #812). Search for any account by name,
  @handle or email and freeze / unfreeze it directly, without waiting for a
  report, plus a paginated list of every account currently in the moderation
  freezer.

  Freezing goes through the public, audited `Vutuv.Moderation.admin_freeze_user/3`
  (not the private `set_user_moderation!/2`): it sets `frozen_at`, which hides
  the profile and everything it owns from everyone but the owner and admins, and
  records a caseless audit row. It does **not** block login — a freeze is a
  profile hold, not a suspension.

  Freeze/unfreeze are `POST`s through the `:browser` pipeline, so they are
  CSRF-protected (the forms carry the token); the classic controller mirrors
  the report-queue POST fallbacks rather than a LiveView because the acceptance
  criteria call for a CSRF-protected form submit.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Moderation
  alias VutuvWeb.ControllerHelpers

  # Most matches shown for a search. An admin narrows the query rather than
  # scrolling; the account they want is reachable by name, @handle or email.
  @results_limit 50

  def index(conn, params) do
    filters = Accounts.admin_user_filters(%{"q" => params["q"], "reg" => "all", "flag" => "all"})

    results =
      if filters.q,
        do: Accounts.list_admin_users(filters, %{}, per_page: @results_limit),
        else: []

    render(conn, "index.html",
      page_title: gettext("Freeze an account"),
      q: to_string(params["q"]),
      searched?: filters.q != nil,
      results: results
    )
  end

  def frozen(conn, params) do
    total = Moderation.frozen_accounts_count()
    accounts = Moderation.list_frozen_accounts(params, total: total)
    report_frozen = Moderation.report_frozen_ids(Enum.map(accounts, & &1.id))

    render(conn, "frozen.html",
      page_title: gettext("Frozen accounts"),
      accounts: accounts,
      report_frozen: report_frozen,
      row_count: total,
      params: params
    )
  end

  def freeze(conn, params), do: toggle(conn, params, :freeze)
  def unfreeze(conn, params), do: toggle(conn, params, :unfreeze)

  defp toggle(conn, %{"id" => id} = params, action) do
    back = safe_return(params["return_to"])

    case ControllerHelpers.get_user(id) do
      nil ->
        conn
        |> put_flash(:error, gettext("That account no longer exists."))
        |> redirect(to: back)

      user ->
        {result, _} = apply_action(action, user, conn.assigns.current_user, params["reason"])

        conn
        |> put_flash(:info, flash_message(action, result, user))
        |> redirect(to: back)
    end
  end

  defp apply_action(:freeze, user, admin, reason),
    do: {elem(Moderation.admin_freeze_user(user, admin, reason), 1), user}

  defp apply_action(:unfreeze, user, admin, reason),
    do: {elem(Moderation.admin_unfreeze_user(user, admin, reason), 1), user}

  defp flash_message(:freeze, :frozen, user),
    do: gettext("@%{username} was frozen.", username: user.username)

  defp flash_message(:freeze, :noop, user),
    do: gettext("@%{username} was already frozen.", username: user.username)

  defp flash_message(:unfreeze, :unfrozen, user),
    do: gettext("@%{username} was unfrozen.", username: user.username)

  defp flash_message(:unfreeze, :noop, user),
    do: gettext("@%{username} was not frozen.", username: user.username)

  # Only ever redirect back inside the admin area. A caller-supplied return_to
  # that is not a local /admin/ path (a full URL, a scheme-relative //host, a
  # different scope) falls back to the frozen list, so the hidden field can
  # never be turned into an open redirect.
  defp safe_return("/admin/" <> _ = path) do
    if String.starts_with?(path, "/admin//"), do: default_return(), else: path
  end

  defp safe_return(_other), do: default_return()

  defp default_return, do: ~p"/admin/accounts/frozen"
end
