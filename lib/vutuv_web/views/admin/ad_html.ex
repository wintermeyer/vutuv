defmodule VutuvWeb.Admin.AdHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../../templates/admin/ad/*")

  @doc """
  The review body an ad shares between the dashboard card and its detail
  page: booker, the ad rendered exactly as visitors would see it, the
  original Markdown source, billing data and price. Reviewing both renderings
  matters - the Markdown source is what was bought, the HTML is what runs.
  """
  attr(:ad, Vutuv.Ads.Ad, required: true)

  def ad_details(assigns) do
    ~H"""
    <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
      <%= if @ad.user do %>
        {gettext("Booked by")}
        <.link href={~p"/#{@ad.user}"} class="font-semibold text-brand-600 hover:text-brand-700">
          @{@ad.user.username}
        </.link>
      <% else %>
        {gettext("Booked by a since-deleted account")}
      <% end %>
      · {gettext("booked on")}
      <.local_time at={@ad.inserted_at} />
    </p>

    <p class="mt-3 text-xs font-semibold uppercase tracking-wide text-slate-500">
      {gettext("Preview (as visitors see it)")}
    </p>
    <div class="markdown mt-1 rounded-lg bg-slate-50 p-3 text-sm text-slate-700 dark:bg-slate-800/60 dark:text-slate-300">
      {VutuvWeb.Markdown.render(@ad.content)}
    </div>

    <p class="mt-3 text-xs font-semibold uppercase tracking-wide text-slate-500">
      {gettext("Markdown source")}
    </p>
    <pre class="mt-1 overflow-x-auto whitespace-pre-wrap rounded-lg bg-slate-50 p-3 font-mono text-xs text-slate-700 dark:bg-slate-800/60 dark:text-slate-300">{@ad.content}</pre>

    <dl class="mt-3 grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
      <div>
        <dt class="text-xs font-semibold uppercase tracking-wide text-slate-500">
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
        <dt class="text-xs font-semibold uppercase tracking-wide text-slate-500">
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
