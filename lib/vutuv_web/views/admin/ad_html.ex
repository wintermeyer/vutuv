defmodule VutuvWeb.Admin.AdHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../../templates/admin/ad/*")

  alias Vutuv.Ads.Ad
  alias VutuvWeb.AdHTML

  @doc """
  A table of bookings for the review page: day, state and booker, and a last
  column the caller fills (a reason, a billing name).
  """
  attr(:id_prefix, :string, required: true)
  attr(:ads, :list, required: true)

  slot :last, required: true do
    attr(:label, :string, required: true)
  end

  def ad_table(assigns) do
    ~H"""
    <div class="card__tablewrap">
      <table class="pure-table">
        <thead>
          <tr>
            <th>{gettext("Day")}</th>
            <th>{gettext("Status")}</th>
            <th>{gettext("Booked by")}</th>
            <th :for={column <- @last}>{column.label}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={ad <- @ads} id={"#{@id_prefix}-#{ad.id}"}>
            <td>
              <.link href={~p"/admin/ads/#{ad}"}>{AdHTML.day_label(ad.day)}</.link>
              <%!-- A week or a month is one purchase, so approving, rejecting
              or cancelling any of its days does it to all of them. The row says
              so, or an admin presses one button and watches six other rows
              change. --%>
              <span :if={ad.group_id} class="block text-xs text-slate-600 dark:text-slate-400">
                {gettext("Part of one booking; a decision here applies to all its days.")}
              </span>
            </td>
            <td>{AdHTML.status_label(ad)}</td>
            <td>
              <%= if ad.user do %>
                <.link href={~p"/#{ad.user}"}>@{ad.user.username}</.link>
              <% else %>
                {gettext("deleted account")}
              <% end %>
            </td>
            <td :for={column <- @last}>{render_slot(column, ad)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  What an admin can still do with a booking, shared by the dashboard card and
  the detail page: approve or reject (with a reason the booker reads) while
  it waits, cancel once approved and before its day. Plus where it stands:
  who decided or withdrew it, and its numbers once it ran.
  """
  attr(:ad, Ad, required: true)

  def ad_review(assigns) do
    ~H"""
    <AdHTML.ad_outcome ad={@ad} />

    <%= case Ad.status(@ad) do %>
      <% :pending -> %>
        <div class="mt-4 flex flex-wrap items-start gap-3">
          <.form for={%{}} id={"approve-#{@ad.id}"} action={~p"/admin/ads/#{@ad}/approve"} method="post">
            <.button type="submit">{gettext("Approve")}</.button>
          </.form>
          <.form
            for={%{}}
            id={"reject-#{@ad.id}"}
            action={~p"/admin/ads/#{@ad}/reject"}
            method="post"
            class="flex min-w-0 flex-1 flex-col gap-2 sm:min-w-72"
          >
            <label for={"reject-reason-#{@ad.id}"} class="sr-only">
              {gettext("Why the ad is rejected")}
            </label>
            <textarea
              id={"reject-reason-#{@ad.id}"}
              name="reason"
              rows="2"
              required
              maxlength="2000"
              placeholder={gettext("Why the ad is rejected (the booker reads this)")}
              class={input_class()}
            ></textarea>
            <.button type="submit" variant="danger-ghost" class="self-start">
              {gettext("Reject")}
            </.button>
          </.form>
        </div>
      <% :approved -> %>
        <.form
          :if={Date.compare(@ad.day, Vutuv.Ads.today()) != :lt}
          for={%{}}
          id={"cancel-#{@ad.id}"}
          action={~p"/admin/ads/#{@ad}/cancel"}
          method="post"
          class="mt-4"
        >
          <.button
            type="submit"
            variant="danger-ghost"
            data-confirm={gettext("Cancel this ad? The booker is told, and the day is free again.")}
          >
            {gettext("Cancel ad")}
          </.button>
        </.form>
      <% _decided -> %>
    <% end %>
    """
  end

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
          {VutuvWeb.AgentDocs.AdsDoc.price_display(@ad.price_cents)}
          <span :if={@ad.vat_id}>· {gettext("VAT ID")}: {@ad.vat_id}</span>
        </dd>
      </div>
    </dl>
    """
  end
end
