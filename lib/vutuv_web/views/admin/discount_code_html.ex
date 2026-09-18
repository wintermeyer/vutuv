defmodule VutuvWeb.Admin.DiscountCodeHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../../templates/admin/discount_code/*")

  alias Vutuv.Ads.DiscountCode
  alias Vutuv.Ads.Discounts
  alias VutuvWeb.AdHTML
  alias VutuvWeb.UI

  @doc "What a code takes off, as the admin list reads it."
  def worth(%DiscountCode{percent_off: percent}) when is_integer(percent), do: "#{percent} %"

  def worth(%DiscountCode{cents_off: cents}) when is_integer(cents),
    do: "#{UI.euro_cents(cents)} €"

  @doc """
  Who may use a code and how far it has been used: the pairing an admin scans
  the list for, because a personalised code that has been used is spent and one
  for everybody never is.
  """
  attr(:code, DiscountCode, required: true)

  def reach(assigns) do
    assigns = assign(assigns, :used, Discounts.live_redemptions(assigns.code))

    ~H"""
    <span :if={@code.user} class="whitespace-nowrap">
      @{@code.user.username}
      <span :if={@used > 0} class="font-semibold text-slate-900 dark:text-slate-100">
        · {gettext("used")}
      </span>
    </span>
    <span :if={is_nil(@code.user)} class="whitespace-nowrap">
      {gettext("everybody")}
      <span :if={@used > 0}>
        · {ngettext("%{count} use", "%{count} uses", @used)}
      </span>
    </span>
    """
  end

  @doc "A code's own day, and whether it has passed."
  attr(:code, DiscountCode, required: true)

  def expiry(assigns) do
    ~H"""
    <span class={[
      "whitespace-nowrap",
      not DiscountCode.live?(@code) && "text-slate-500 line-through dark:text-slate-400"
    ]}>
      {AdHTML.day_label(@code.expires_on)}
    </span>
    """
  end
end
