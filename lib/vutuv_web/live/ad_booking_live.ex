defmodule VutuvWeb.AdBookingLive do
  @moduledoc """
  Booking an ad, at `/system/ads/new`, in three steps a person can hold in
  their head: write it, pick when it runs, say where the invoice goes.

  **Why a LiveView and not the form it replaced.** The old page asked for the
  three lines, the day and the invoice address all at once, then showed the ad
  on a separate preview page — so the one question a buyer actually has ("what
  will this look like?") was answered after they had filled in everything else,
  and a mistake sent them back through the whole form. Here the card is drawn
  from what they are typing, by the very component a profile and the feed use,
  and each step asks one thing.

  **The text can be saved and used again** (`Vutuv.Ads.Creative`). Booking
  copies the text onto the `ads` rows rather than pointing at the saved one, so
  editing a saved ad never rewrites an ad that is already running or already on
  an invoice.

  **The calendar shows the whole booking window** — this month and the next
  three (`Vutuv.Ads.last_bookable_day/0`) — and it works in the unit being
  bought: with a week chosen, a day is offered as a start only when all seven
  days behind it are free (`Vutuv.Ads.free_block?/3`), and picking it marks all
  seven. Hovering marks them too, without a round trip, which is what makes a
  free stretch findable by eye (`assets/js/ad_calendar.js`).
  """

  use VutuvWeb, :live_view

  import VutuvWeb.ErrorHelpers, only: [error_tag: 2]

  alias Vutuv.Ads
  alias Vutuv.Ads.Ad
  alias Vutuv.Ads.Creative
  alias VutuvWeb.AdComponents
  alias VutuvWeb.AdHTML
  alias VutuvWeb.AgentDocs.AdsDoc
  alias VutuvWeb.Live.InitAssigns

  on_mount({InitAssigns, :require_login})

  @steps [:text, :period, :billing]

  @impl true
  def mount(_params, _session, socket) do
    # The router's pipeline already 404s a request while ads are off; this
    # covers a live navigation, which skips the pipeline.
    if Ads.enabled?() do
      {:ok, start_wizard(socket)}
    else
      {:ok, InitAssigns.not_found(socket)}
    end
  end

  defp start_wizard(socket) do
    user = socket.assigns.current_user

    socket
    |> assign(:page_title, gettext("Book your ad"))
    |> assign(:step, :text)
    |> assign(:steps, @steps)
    |> assign(:days, 1)
    |> assign(:start_day, nil)
    |> assign(:booking_error, nil)
    |> assign(:saved_notice, nil)
    |> assign(:creatives, Ads.list_creatives(user))
    |> assign(:creative, nil)
    |> assign_text_form(%{})
    # The invoice address somebody already gave us is not a question worth
    # asking twice, so a returning booker meets it filled in.
    |> assign_billing_form(previous_billing(user))
    |> assign_calendar()
  end

  ## Step 1: the ad itself

  @impl true
  def handle_event("validate-text", %{"ad" => params}, socket) do
    {:noreply, socket |> assign_text_form(params) |> assign(:saved_notice, nil)}
  end

  def handle_event("to-period", %{"ad" => params}, socket) do
    socket = assign_text_form(params, socket, :insert)

    if socket.assigns.text_form.source.valid? do
      {:noreply, assign(socket, :step, :period)}
    else
      {:noreply, socket}
    end
  end

  # The save button is not a submit, so it carries no form values: what gets
  # saved is what the socket already holds from the last `validate-text`.
  def handle_event("save-text", _params, socket) do
    user = socket.assigns.current_user
    params = saved_params(socket)

    case Ads.save_creative(user, params, socket.assigns.creative) do
      {:ok, creative} ->
        {:noreply,
         socket
         |> assign(:creatives, Ads.list_creatives(user))
         |> assign(:creative, creative)
         |> assign(:saved_notice, gettext("Saved. You can pick this ad again next time."))}

      {:error, :too_many} ->
        {:noreply,
         assign(
           socket,
           :saved_notice,
           gettext("You already keep %{count} saved ads. Delete one first.",
             count: Ads.creative_cap()
           )
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :text_form, to_form(%{changeset | action: :insert}))}
    end
  end

  def handle_event("use-creative", %{"id" => id}, socket) do
    case Ads.get_creative(socket.assigns.current_user, id) do
      nil ->
        {:noreply, socket}

      %Creative{} = creative ->
        params = %{"title" => creative.title, "body" => creative.body, "url" => creative.url}

        {:noreply,
         socket
         |> assign(:creative, creative)
         |> assign(:saved_notice, nil)
         |> assign_text_form(params)}
    end
  end

  def handle_event("forget-creative", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    Ads.delete_creative(user, id)

    creative = if socket.assigns.creative && socket.assigns.creative.id == id, do: nil

    {:noreply,
     socket
     |> assign(:creatives, Ads.list_creatives(user))
     |> assign(:creative, creative)
     |> assign(:saved_notice, nil)}
  end

  ## Step 2: when it runs

  def handle_event("pick-length", %{"days" => days}, socket) do
    days = String.to_integer(days)

    if Ads.tier(days) do
      # A start that fitted a single day rarely fits a month, so a length
      # change drops a selection it would otherwise invalidate silently.
      start_day =
        if start_fits?(socket, socket.assigns.start_day, days), do: socket.assigns.start_day

      {:noreply, socket |> assign(:days, days) |> assign(:start_day, start_day)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pick-day", %{"day" => day}, socket) do
    with {:ok, day} <- Date.from_iso8601(day),
         true <- start_fits?(socket, day, socket.assigns.days) do
      {:noreply, assign(socket, :start_day, day)}
    else
      _unavailable -> {:noreply, socket}
    end
  end

  def handle_event("to-billing", _params, socket) do
    if socket.assigns.start_day do
      {:noreply, assign(socket, :step, :billing)}
    else
      {:noreply, socket}
    end
  end

  ## Step 3: the invoice address, then the binding booking

  def handle_event("validate-billing", %{"ad" => params}, socket) do
    {:noreply, assign_billing_form(socket, params)}
  end

  def handle_event("book", %{"ad" => params}, socket) do
    attrs = booking_attrs(socket, params)

    case Ads.book_ad(socket.assigns.current_user, attrs, socket.assigns.days) do
      {:ok, ad} ->
        {:noreply,
         socket
         |> put_flash(:info, booked_flash(ad, socket.assigns.days))
         |> push_navigate(to: ~p"/system/ads/bookings")}

      {:error, changeset} ->
        # Anything the invoice fields can be wrong about belongs on this step;
        # a day that went while they were typing belongs back on the calendar,
        # with the calendar reloaded so the day is struck through there.
        {:noreply, show_booking_error(socket, changeset)}
    end
  end

  def handle_event("back", %{"to" => step}, socket) do
    step = String.to_existing_atom(step)
    {:noreply, if(step in @steps, do: assign(socket, :step, step), else: socket)}
  end

  ## Assign helpers

  defp saved_params(socket) do
    text = socket.assigns.text
    %{"title" => text.title, "body" => text.body, "url" => text.url}
  end

  defp assign_text_form(socket, params), do: assign_text_form(params, socket, nil)

  defp assign_text_form(params, socket, action) do
    changeset = Ads.change_creative(socket.assigns[:creative] || %Creative{}, params)
    changeset = if action, do: %{changeset | action: action}, else: changeset

    socket
    |> assign(:text_form, to_form(changeset))
    |> assign(:text, text_params(params))
  end

  # What the preview card draws, straight from what is typed - never through a
  # changeset, so a half-written ad still shows itself.
  defp text_params(params) do
    %Ad{
      title: params["title"] || "",
      body: params["body"] || "",
      url: params["url"] || ""
    }
  end

  defp assign_billing_form(socket, params) do
    assign(socket, :billing_form, to_form(params, as: :ad))
  end

  defp previous_billing(user) do
    case Ads.user_bookings(user) do
      [%{ad: ad} | _rest] ->
        Map.new(
          ~w(billing_name billing_company billing_street billing_zip_code billing_city
             billing_country vat_id)a,
          fn field -> {Atom.to_string(field), Map.get(ad, field) || ""} end
        )

      [] ->
        %{}
    end
  end

  defp assign_calendar(socket) do
    assign(socket, :taken, Ads.booked_days())
  end

  defp start_fits?(_socket, nil, _days), do: false

  defp start_fits?(socket, %Date{} = day, days) do
    Date.compare(day, Ads.first_bookable_day()) != :lt and
      Ads.free_block?(day, days, socket.assigns.taken)
  end

  defp booking_attrs(socket, params) do
    text = socket.assigns.text

    params
    |> Map.take(~w(billing_name billing_company billing_street billing_zip_code billing_city
         billing_country vat_id))
    |> Map.merge(%{
      "day" => Date.to_iso8601(socket.assigns.start_day),
      "title" => text.title,
      "body" => text.body,
      "url" => text.url
    })
  end

  defp show_booking_error(socket, changeset) do
    socket = socket |> assign_calendar() |> assign(:billing_form, to_form(changeset))

    if changeset.errors[:day] do
      socket
      |> assign(:step, :period)
      |> assign(:start_day, nil)
      |> assign(
        :booking_error,
        gettext(
          "Somebody booked one of those days while you were filling this in. Please pick another stretch."
        )
      )
    else
      assign(socket, :booking_error, nil)
    end
  end

  defp booked_flash(ad, 1) do
    gettext(
      "Your ad for %{day} is booked. We will review and approve it shortly; the invoice follows by email.",
      day: AdHTML.day_label(ad.day)
    )
  end

  defp booked_flash(ad, days) do
    gettext(
      "Your ad is booked for %{period}. We will review and approve it shortly; the invoice follows by email.",
      period: AdHTML.period_label(ad.day, days)
    )
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl py-6">
      <.step_bar step={@step} />

      <.text_step :if={@step == :text} {assigns} />
      <.period_step :if={@step == :period} {assigns} />
      <.billing_step :if={@step == :billing} {assigns} />
    </div>
    """
  end

  # Three numbered steps, because the reader is buying something and wants to
  # know how much of it is left. Names, not "Step 2 of 3" alone: the words are
  # what tell them what is still coming.
  attr(:step, :atom, required: true)

  defp step_bar(assigns) do
    assigns = assign(assigns, :labels, [gettext("Your ad"), gettext("When"), gettext("Invoice")])

    ~H"""
    <ol class="mb-6 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
      <li :for={{label, index} <- Enum.with_index(@labels)} class="flex items-center gap-2">
        <span
          class={[
            "grid size-6 shrink-0 place-items-center rounded-full text-xs font-bold",
            step_index(@step) >= index && "bg-brand-600 text-white",
            step_index(@step) < index && "bg-slate-200 text-slate-600 dark:bg-slate-700 dark:text-slate-300"
          ]}
          aria-hidden="true"
        >
          {index + 1}
        </span>
        <span class={[
          "font-semibold",
          step_index(@step) == index && "text-slate-900 dark:text-slate-100",
          step_index(@step) != index && "text-slate-600 dark:text-slate-400"
        ]}>
          {label}
        </span>
        <span :if={index < 2} aria-hidden="true" class="px-1 text-slate-400">›</span>
      </li>
    </ol>
    """
  end

  defp step_index(step), do: Enum.find_index(@steps, &(&1 == step))

  defp text_step(assigns) do
    ~H"""
    <div class="grid gap-6 md:grid-cols-5">
      <.card class="min-w-0 p-6 md:col-span-3">
        <h1 class="text-xl font-bold text-slate-900 dark:text-slate-100">
          {gettext("Write your ad")}
        </h1>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {gettext("Three lines. You see the result as you type.")}
        </p>

        <.form
          for={@text_form}
          id="ad-text-form"
          phx-change="validate-text"
          phx-submit="to-period"
          class="mt-5 space-y-4"
        >
          <.form_error changeset={@text_form.source} />

          <div>
            <label for="ad-title" class="block text-sm font-medium text-slate-700 dark:text-slate-300">
              {gettext("Title")}
            </label>
            <input
              type="text"
              id="ad-title"
              name="ad[title]"
              value={@text.title}
              maxlength={Ad.title_max_length()}
              phx-debounce="150"
              class={input_class(@text_form, :title)}
            />
            <p class="mt-1 flex justify-between gap-2 text-xs text-slate-600 dark:text-slate-400">
              <span>{gettext("Shown as the link, in bold.")}</span>
              <span>{String.length(@text.title)}/{Ad.title_max_length()}</span>
            </p>
            {error_tag(@text_form, :title)}
          </div>

          <div>
            <label for="ad-body" class="block text-sm font-medium text-slate-700 dark:text-slate-300">
              {gettext("Text")}
            </label>
            <input
              type="text"
              id="ad-body"
              name="ad[body]"
              value={@text.body}
              maxlength={Ad.body_max_length()}
              phx-debounce="150"
              class={input_class(@text_form, :body)}
            />
            <p class="mt-1 flex justify-between gap-2 text-xs text-slate-600 dark:text-slate-400">
              <span>{gettext("One sentence under the title, plain text.")}</span>
              <span>{String.length(@text.body)}/{Ad.body_max_length()}</span>
            </p>
            {error_tag(@text_form, :body)}
          </div>

          <div>
            <label for="ad-url" class="block text-sm font-medium text-slate-700 dark:text-slate-300">
              {gettext("Link")}
            </label>
            <input
              type="url"
              id="ad-url"
              name="ad[url]"
              value={@text.url}
              phx-debounce="300"
              placeholder="https://"
              class={input_class(@text_form, :url)}
            />
            <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
              {gettext("Where the title leads. Readers see the address without its query, so they know where they are going.")}
            </p>
            {error_tag(@text_form, :url)}
          </div>

          <div class="flex flex-wrap items-center gap-3 pt-2">
            <.button type="submit">{gettext("Next: pick the days")}</.button>
            <.button type="button" variant="secondary" phx-click="save-text">
              {gettext("Save this ad")}
            </.button>
          </div>
        </.form>
        <p :if={@saved_notice} class="mt-2 text-xs font-semibold text-brand-700 dark:text-brand-300">
          {@saved_notice}
        </p>
      </.card>

      <div class="min-w-0 space-y-6 md:col-span-2">
        <.card class="p-6">
          <.section_title>{gettext("How it will look")}</.section_title>
          <AdComponents.ad_preview id="wizard-preview" banner={{:ad, @text}} class="mt-3" />
        </.card>

        <.card :if={@creatives != []} class="p-6">
          <.section_title>{gettext("Your saved ads")}</.section_title>
          <ul class="mt-3 divide-y divide-slate-100 dark:divide-slate-800">
            <li :for={creative <- @creatives} class="flex items-start gap-3 py-2 first:pt-0 last:pb-0">
              <button
                type="button"
                phx-click="use-creative"
                phx-value-id={creative.id}
                class="min-w-0 flex-1 text-left"
              >
                <span class="block truncate text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300">
                  {creative.title}
                </span>
                <span class="block truncate text-xs text-slate-600 dark:text-slate-400">
                  {creative.body}
                </span>
              </button>
              <button
                type="button"
                phx-click="forget-creative"
                phx-value-id={creative.id}
                data-confirm={gettext("Delete this saved ad?")}
                aria-label={gettext("Delete this saved ad")}
                title={gettext("Delete this saved ad")}
                class="grid size-10 shrink-0 place-items-center rounded-lg text-slate-600 hover:bg-slate-100 hover:text-red-600 dark:text-slate-400 dark:hover:bg-slate-800"
              >
                ✕
              </button>
            </li>
          </ul>
        </.card>
      </div>
    </div>
    """
  end

  defp period_step(assigns) do
    ~H"""
    <div class="grid gap-6 md:grid-cols-5">
      <.card class="min-w-0 p-6 md:col-span-3">
        <h1 class="text-xl font-bold text-slate-900 dark:text-slate-100">
          {gettext("When should it run?")}
        </h1>

        <p
          :if={@booking_error}
          id="booking-error"
          role="alert"
          class="mt-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-900/30 dark:text-red-200"
        >
          {@booking_error}
        </p>

        <fieldset class="mt-4">
          <legend class="text-sm font-medium text-slate-700 dark:text-slate-300">
            {gettext("How long")}
          </legend>
          <div class="mt-2 grid gap-2 sm:grid-cols-3">
            <button
              :for={line <- AdsDoc.tier_lines()}
              type="button"
              phx-click="pick-length"
              phx-value-days={line.days}
              aria-pressed={to_string(@days == line.days)}
              class={[
                "rounded-xl border p-3 text-left",
                @days == line.days && "border-brand-600 bg-brand-50 dark:bg-brand-800/60",
                @days != line.days &&
                  "border-slate-200 hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-800"
              ]}
            >
              <span class="block text-sm font-semibold text-slate-900 dark:text-slate-100">
                {line.price}
              </span>
              <span :if={line.saving} class="block text-xs text-brand-700 dark:text-brand-300">
                {line.saving}
              </span>
            </button>
          </div>
        </fieldset>

        <p class="mt-4 text-sm text-slate-600 dark:text-slate-400">
          <%= if @days == 1 do %>
            {gettext("Pick a free day. Struck-through days are already booked.")}
          <% else %>
            {gettext("Pick the day it starts. Only days with %{days} free days behind them can be picked, and picking one marks the whole stretch.", days: @days)}
          <% end %>
        </p>

        <div
          id="ad-calendar"
          phx-hook="AdCalendar"
          data-days={@days}
          class="mt-4 grid gap-6 sm:grid-cols-2"
        >
          <div :for={month <- AdHTML.calendar_months()} data-calendar-month>
            <p class="text-sm font-semibold text-slate-700 dark:text-slate-300">{month.title}</p>
            <div class="mt-2 grid grid-cols-7 gap-1 text-center text-xs">
              <span
                :for={wd <- AdHTML.weekday_initials()}
                class="py-1 font-semibold text-slate-600 dark:text-slate-400"
              >
                {wd}
              </span>
              <%= for week <- month.weeks, cell <- week do %>
                <.calendar_cell cell={cell} days={@days} start_day={@start_day} taken={@taken} />
              <% end %>
            </div>
          </div>
        </div>

        <div class="mt-6 flex flex-wrap items-center gap-3">
          <.button type="button" variant="secondary" phx-click="back" phx-value-to="text">
            {gettext("Back")}
          </.button>
          <.button type="button" phx-click="to-billing" disabled={is_nil(@start_day)}>
            {gettext("Next: the invoice")}
          </.button>
        </div>
      </.card>

      <div class="min-w-0 space-y-6 md:col-span-2">
        <.card class="p-6">
          <.section_title>{gettext("Your ad")}</.section_title>
          <AdComponents.ad_preview id="period-preview" banner={{:ad, @text}} class="mt-3" />
        </.card>
        <.order_summary days={@days} start_day={@start_day} />
      </div>
    </div>
    """
  end

  # One day of the calendar. A cell that cannot start the chosen block is not a
  # control at all, so it is a span: a disabled button is still a tab stop, and
  # in a 120-day grid that is 120 of them.
  attr(:cell, :any, required: true)
  attr(:days, :integer, required: true)
  attr(:start_day, :any, required: true)
  attr(:taken, :any, required: true)

  defp calendar_cell(%{cell: nil} = assigns), do: ~H"<span></span>"

  defp calendar_cell(%{cell: {day, :booked}} = assigns) do
    assigns = assign(assigns, :day, day)

    ~H"""
    <span
      data-calendar-day={@day}
      title={gettext("already booked")}
      class="block rounded-lg bg-slate-100 py-1.5 text-slate-600 line-through dark:bg-slate-800 dark:text-slate-500"
    >
      {@day.day}
    </span>
    """
  end

  defp calendar_cell(%{cell: {day, :unavailable}} = assigns) do
    assigns = assign(assigns, :day, day)

    ~H"""
    <span class="block py-1.5 text-slate-400 dark:text-slate-500">{@day.day}</span>
    """
  end

  defp calendar_cell(%{cell: {day, :free}} = assigns) do
    assigns =
      assigns
      |> assign(:day, day)
      |> assign(:selectable?, Ads.free_block?(day, assigns.days, assigns.taken))
      |> assign(:in_block?, in_block?(day, assigns.start_day, assigns.days))

    ~H"""
    <button
      :if={@selectable?}
      type="button"
      data-day={Date.to_iso8601(@day)}
      phx-click="pick-day"
      phx-value-day={Date.to_iso8601(@day)}
      aria-pressed={to_string(@in_block?)}
      class={[
        "block w-full rounded-lg py-1.5 ring-1",
        @in_block? && "bg-brand-600 font-bold text-white ring-brand-600",
        !@in_block? &&
          "ring-slate-200 hover:bg-brand-50 dark:ring-slate-700 dark:hover:bg-brand-800/40"
      ]}
    >
      {@day.day}
    </button>
    <%!-- Free, but not enough room behind it for the chosen length. Shown as
    an ordinary day rather than struck through: nothing is booked there, and
    saying "taken" about a free day would be a lie. --%>
    <span
      :if={!@selectable?}
      data-day={Date.to_iso8601(@day)}
      data-block-target
      class={[
        "block rounded-lg py-1.5",
        @in_block? && "bg-brand-600 font-bold text-white",
        !@in_block? && "text-slate-500 dark:text-slate-400"
      ]}
    >
      {@day.day}
    </span>
    """
  end

  defp in_block?(_day, nil, _days), do: false

  defp in_block?(day, start_day, days) do
    Date.compare(day, start_day) != :lt and
      Date.compare(day, Date.add(start_day, days - 1)) != :gt
  end

  attr(:days, :integer, required: true)
  attr(:start_day, :any, required: true)

  defp order_summary(assigns) do
    ~H"""
    <.card class="p-6">
      <.section_title>{gettext("Your booking")}</.section_title>
      <dl class="mt-3 space-y-2 text-sm">
        <div>
          <dt class="m-0 border-t-0 p-0 text-sm text-slate-600 dark:text-slate-400">
            {ngettext("Day", "Days", @days)}
          </dt>
          <dd class="m-0 mt-1 text-lg font-bold text-slate-900 dark:text-slate-100">
            <%= if @start_day do %>
              {AdHTML.period_label(@start_day, @days)}
            <% else %>
              {gettext("not picked yet")}
            <% end %>
          </dd>
        </div>
        <div>
          <dt class="m-0 border-t-0 p-0 text-sm text-slate-600 dark:text-slate-400">
            {gettext("Price")}
          </dt>
          <dd class="m-0 mt-1 text-lg font-bold text-slate-900 dark:text-slate-100">
            {AdHTML.block_price(@days)}
          </dd>
          <dd
            :if={AdHTML.block_vat(@days)}
            class="m-0 text-sm font-normal text-slate-600 dark:text-slate-400"
          >
            {AdHTML.block_vat(@days)}
          </dd>
        </div>
      </dl>
    </.card>
    """
  end

  defp billing_step(assigns) do
    ~H"""
    <div class="grid gap-6 md:grid-cols-5">
      <.card class="min-w-0 p-6 md:col-span-3">
        <h1 class="text-xl font-bold text-slate-900 dark:text-slate-100">
          {gettext("Where does the invoice go?")}
        </h1>

        <.form
          for={@billing_form}
          id="ad-billing-form"
          phx-change="validate-billing"
          phx-submit="book"
          class="mt-5 space-y-4"
        >
          <.billing_field form={@billing_form} field={:billing_name} label={gettext("Billing name")} />
          <.billing_field
            form={@billing_form}
            field={:billing_company}
            label={gettext("Company (optional)")}
          />
          <.billing_field form={@billing_form} field={:billing_street} label={gettext("Street")} />
          <div class="grid gap-4 sm:grid-cols-3">
            <.billing_field
              form={@billing_form}
              field={:billing_zip_code}
              label={gettext("Postal code")}
            />
            <div class="sm:col-span-2">
              <.billing_field form={@billing_form} field={:billing_city} label={gettext("City")} />
            </div>
          </div>
          <.billing_field form={@billing_form} field={:billing_country} label={gettext("Country")} />
          <.billing_field form={@billing_form} field={:vat_id} label={gettext("VAT ID (optional)")} />

          <p class="text-xs text-slate-600 dark:text-slate-400">
            {gettext("Booking is binding; payment by invoice. We review and approve every ad before it runs.")}
          </p>

          <div class="flex flex-wrap items-center gap-3 pt-2">
            <.button type="button" variant="secondary" phx-click="back" phx-value-to="period">
              {gettext("Back")}
            </.button>
            <.button type="submit" id="confirm-booking">
              {gettext("Book now (binding, by invoice)")}
            </.button>
          </div>
        </.form>
      </.card>

      <div class="min-w-0 space-y-6 md:col-span-2">
        <.card class="p-6">
          <.section_title>{gettext("Your ad")}</.section_title>
          <AdComponents.ad_preview id="billing-preview" banner={{:ad, @text}} class="mt-3" />
        </.card>
        <.order_summary days={@days} start_day={@start_day} />
      </div>
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:field, :atom, required: true)
  attr(:label, :string, required: true)

  defp billing_field(assigns) do
    ~H"""
    <div>
      <label
        for={"ad-#{@field}"}
        class="block text-sm font-medium text-slate-700 dark:text-slate-300"
      >
        {@label}
      </label>
      <input
        type="text"
        id={"ad-#{@field}"}
        name={"ad[#{@field}]"}
        value={Phoenix.HTML.Form.input_value(@form, @field)}
        class={input_class(@form, @field)}
      />
      {error_tag(@form, @field)}
    </div>
    """
  end
end
