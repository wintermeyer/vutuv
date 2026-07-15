defmodule VutuvWeb.Admin.MemberBadges do
  @moduledoc """
  The account-status badges an admin sees on a member, shared by the member
  browser (`VutuvWeb.Admin.UserLive`) and the member detail page
  (`VutuvWeb.Admin.UserDetailLive`) so the two never drift. `status_badges/1`
  returns the exceptional-status pills as `{label, tone}` tuples in a fixed
  order; `badge_class/1` maps a tone to its pill colours. The PIN/Unconfirmed
  registration pill is not an exceptional status, so each page renders it inline
  and it is not part of this list.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User

  @doc "The exceptional status badges a member carries, in order, as `{label, tone}` tuples."
  def status_badges(%User{} = user) do
    [
      user.admin? && {gettext("Admin"), :admin},
      user.identity_verified? && {gettext("Verified"), :verified},
      user.frozen_at && {gettext("Frozen"), :warn},
      user.suspended_until && {gettext("Suspended"), :warn},
      user.moderation_reason == "spam" && {gettext("Spam"), :danger},
      user.deactivated_at && {gettext("Deactivated"), :danger},
      user.unreachable_at && {gettext("Unreachable"), :danger}
    ]
    |> Enum.filter(& &1)
  end

  @doc "The pill colour classes for a badge `tone`."
  def badge_class(:admin),
    do: "bg-brand-100 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  def badge_class(:verified),
    do: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-200"

  def badge_class(:warn),
    do: "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200"

  def badge_class(:danger),
    do: "bg-rose-100 text-rose-700 dark:bg-rose-900/40 dark:text-rose-200"
end
