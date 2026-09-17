defmodule VutuvWeb.Admin.AdHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../../templates/admin/ad/*")

  @doc """
  The review body an ad shares between the dashboard card and its detail
  page: booker, the ad as visitors will see it, its link in full, billing data
  and price. The full link matters: the card shows the address without its
  query, and the reviewer has to see where the click really goes.
  """
  attr(:ad, Vutuv.Ads.Ad, required: true)

  def ad_details(assigns) do
    ~H"""
    <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
      <%= if @ad.user do %>
        {gettext("Booked by")}
        <.link href={~p"/#{@ad.user}"} class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300">
          @{@ad.user.username}
        </.link>
      <% else %>
        {gettext("Booked by a since-deleted account")}
      <% end %>
      · {gettext("booked on")}
      <.local_time at={@ad.inserted_at} />
    </p>

    <p class="mt-3 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
      {gettext("Preview (as visitors see it)")}
    </p>
    <VutuvWeb.AdComponents.ad_preview id={"admin-ad-#{@ad.id}-card"} banner={{:ad, @ad}} class="mt-1" />

    <p class="mt-3 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
      {gettext("Link")}
    </p>
    <p class="mt-1 break-all font-mono text-xs text-slate-700 dark:text-slate-300">{@ad.url}</p>

    <dl class="mt-3 grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
      <div>
        <dt class="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
          {gettext("Billing address")}
        </dt>
        <dd class="mt-1 whitespace-pre-line text-slate-700 dark:text-slate-300">{[
          @ad.billing_name,
          @ad.billing_company,
          @ad.billing_street,
          "#{@ad.billing_zip_code} #{@ad.billing_city}",
          @ad.billing_country
        ]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n")}</dd>
      </div>
      <div>
        <dt class="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
          {gettext("Price")}
        </dt>
        <dd class="mt-1 text-slate-700 dark:text-slate-300">
          {VutuvWeb.AgentDocs.AdsDoc.price_display()}
          <span :if={@ad.vat_id}>· {gettext("VAT ID")}: {@ad.vat_id}</span>
        </dd>
      </div>
    </dl>
    """
  end
end
