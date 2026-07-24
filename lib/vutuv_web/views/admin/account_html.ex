defmodule VutuvWeb.Admin.AccountHTML do
  @moduledoc """
  Renders the admin account freezer pages (issue #812): the search + freeze
  page and the paginated frozen-accounts list.
  """

  use VutuvWeb, :html

  import VutuvWeb.UserHelpers, only: [member_name: 1]

  embed_templates("../../templates/admin/account/*")

  @doc """
  The freeze / unfreeze form for one account row: a CSRF-protected POST to the
  matching admin route. Renders "Unfreeze" for an already-frozen account and
  "Freeze" otherwise. `return_to` rides along so the redirect lands back on the
  page the admin acted from.
  """
  attr(:user, :any, required: true)
  attr(:frozen?, :boolean, required: true)
  attr(:return_to, :string, required: true)

  def freeze_toggle(%{frozen?: true} = assigns) do
    ~H"""
    <.form for={%{}} action={~p"/admin/accounts/#{@user.id}/unfreeze"} class="inline">
      <input type="hidden" name="return_to" value={@return_to} />
      <button
        type="submit"
        class="rounded-lg bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
      >
        {gettext("Unfreeze")}
      </button>
    </.form>
    """
  end

  def freeze_toggle(assigns) do
    ~H"""
    <.form for={%{}} action={~p"/admin/accounts/#{@user.id}/freeze"} class="inline">
      <input type="hidden" name="return_to" value={@return_to} />
      <button
        type="submit"
        class="rounded-lg bg-brand-600 px-3 py-1 text-xs font-semibold text-white hover:bg-brand-700"
      >
        {gettext("Freeze")}
      </button>
    </.form>
    """
  end

  @doc """
  A small status pill for an account: the most severe moderation/deliverability
  state the row carries (deactivated > suspended > frozen > unreachable >
  unconfirmed), or a calm "active" when none applies.
  """
  attr(:user, :any, required: true)

  def account_status(assigns) do
    assigns = assign(assigns, :state, account_state(assigns.user))

    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
      status_classes(@state)
    ]}>
      {status_label(@state)}
    </span>
    """
  end

  # The most severe state first — a row can carry several flags at once.
  defp account_state(user) do
    cond do
      user.deactivated_at != nil -> :deactivated
      suspended?(user) -> :suspended
      user.frozen_at != nil -> :frozen
      user.unreachable_at != nil -> :unreachable
      user.email_confirmed? == false -> :unconfirmed
      true -> :active
    end
  end

  defp suspended?(%{suspended_until: nil}), do: false

  defp suspended?(%{suspended_until: until}),
    do: NaiveDateTime.compare(until, NaiveDateTime.utc_now()) == :gt

  defp status_label(:deactivated), do: gettext("deactivated")
  defp status_label(:suspended), do: gettext("suspended")
  defp status_label(:frozen), do: gettext("frozen")
  defp status_label(:unreachable), do: gettext("unreachable")
  defp status_label(:unconfirmed), do: gettext("unconfirmed")
  defp status_label(:active), do: gettext("active")

  defp status_classes(:active),
    do: "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-200"

  defp status_classes(:unconfirmed),
    do: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"

  defp status_classes(_hold),
    do: "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-200"

  @doc """
  The frozen list's "Source" label: an account currently frozen by an open
  report shows "report", one frozen by an admin shows "admin".
  """
  def freeze_source_label(true), do: gettext("report")
  def freeze_source_label(false), do: gettext("admin")
end
