defmodule VutuvWeb.AdHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Ads.Ad

  embed_templates("../templates/ad/*")

  def status_label(%Ad{approved_at: nil}), do: gettext("Waiting for approval")
  def status_label(%Ad{}), do: gettext("Approved")

  @doc """
  The approval-state pill shown on the member dashboard and the admin review
  page. Green once approved; neutral while the review is pending (amber is
  reserved for moderation notices).
  """
  attr(:ad, Ad, required: true)

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-bold",
      if(@ad.approved_at,
        do: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-200",
        else: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"
      )
    ]}>
      {status_label(@ad)}
    </span>
    """
  end
end
