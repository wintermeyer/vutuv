defmodule VutuvWeb.WelcomeComponents do
  @moduledoc """
  The one-time welcome questions — where you are, whether you are looking, who
  to follow — and the two frames they are shown in.

  `welcome_form/1` is **one step** of them, as a form posting to
  `/system/welcome`; `Vutuv.Welcome` owns which steps a member gets and the
  controller which one they are on. It is rendered in two places and nowhere
  else:

    * `welcome_modal/1`, the frame a new member actually meets. It floats over
      the profile the registration PIN handed them, so the page underneath says
      "you are in" and the questions read as an offer. It carries **no greeting
      and no preamble** — it opens on the first question, and the ✕ beside it
      says what a paragraph about optionality would have said. **Every way out
      of it is the same submit**: the ✕, the "Skip for now" button and (through
      app.js) Esc and a click on the backdrop all carry `skip`, so closing the
      window stamps `welcome_completed_at` and nobody is asked again. That also
      keeps it working with JavaScript off, where the two buttons are ordinary
      submits.
    * `VutuvWeb.WelcomeHTML`'s `/system/welcome` page, which is where a
      **rejected** submit lands (a POST cannot re-open a modal over a page it
      does not render). Rare — the fields are lax and capped in the markup —
      and the same form, so the member sees what they typed with the one bad
      field marked.

  The ✕ belongs to the form through `form=` and is rendered **after** it, never
  above the fields: a form's default submit button is the first one in tree
  order, so a ✕ placed first would be what Enter presses while the member is
  typing their city — the one keystroke that must save, skipping instead.
  """
  use VutuvWeb, :html

  import VutuvWeb.UserHelpers,
    only: [
      employment_status_options: 0,
      desired_salary_currency_options: 0,
      desired_salary_period_options: 0,
      desired_workplace_options: 0,
      visibility_options: 0
    ]

  # The globe-badged tile every surface uses for an account from another
  # network, so a suggestion here looks like the same thing it will look like
  # in the feed.
  import VutuvWeb.PostComponents, only: [remote_avatar: 1]

  alias Phoenix.HTML.Form
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Profiles.Address
  alias Vutuv.Welcome
  alias VutuvWeb.AddressHTML

  @doc """
  The welcome questions floating over whatever page the member is on.

  Rendered by `root.html.heex` while `VutuvWeb.Plug.WelcomeModal` says this
  request is the one-shot window (a brand-new member, sent here by their
  registration PIN, who has not answered or closed it yet). That plug carries
  only the cheap half — the session's step and the path to come back to — and
  the step list and its suggestions are resolved **here**, at render time, so a
  response that never renders the layout never pays for them (the `ad_banner`
  arrangement, for the same reason).

  Both changesets are built here, empty: the modal never renders errors — a
  rejected submit is answered with the `/system/welcome` page.
  """
  attr(:user, User, required: true)
  attr(:stored_step, :atom, default: nil, doc: "the `:welcome_step` session value, if any")
  attr(:return_to, :string, default: nil, doc: "the path this window is floating over")

  def welcome_modal(assigns) do
    window = Welcome.window(assigns.user, Gettext.get_locale(VutuvWeb.Gettext))

    assigns =
      assign(assigns,
        steps: window.steps,
        step: Welcome.current_step(window.steps, assigns.stored_step),
        suggestions: window.suggestions,
        address_changeset: Address.welcome_changeset(%Address{}, %{}),
        # `change/1`, not `User.changeset/2`: the fields read their values off
        # the struct either way, and the full profile-form pipeline (69 cast
        # fields, 43 validations) would run on every page the modal follows the
        # member to, for a form that never renders an error.
        user_changeset: Ecto.Changeset.change(assigns.user)
      )

    ~H"""
    <div
      id="welcome-modal"
      class="fixed inset-0 z-[60] flex items-end justify-center sm:items-center sm:p-4"
      role="dialog"
      aria-modal="true"
      aria-label={gettext("Welcome")}
      data-block-shortcuts
    >
      <div data-welcome-backdrop class="absolute inset-0 bg-slate-900/50 backdrop-blur-sm"></div>
      <%!-- A sheet on a phone (full width, rounded top edge), a centred card
      from sm up. Taller than the window on a small screen, so it scrolls
      itself and the page behind keeps its own scroll position. --%>
      <%!-- No greeting and no preamble above the questions (Stefan, 2026-09-03):
      the window opens on the first question, and what a member needs to know
      about it — that it is optional and closes — the ✕ and "Erstmal
      überspringen" say better than a paragraph nobody reads. The padding stays
      symmetric (no pr-12 for the ✕): the first line is the short "Art der
      Adresse" legend, which ends far left of it in every locale. --%>
      <div class="relative max-h-[90dvh] w-full overflow-y-auto rounded-t-2xl bg-white p-6 shadow-xl ring-1 ring-slate-200 sm:max-w-lg sm:rounded-2xl dark:bg-slate-900 dark:ring-slate-800">
        <.welcome_form
          address_changeset={@address_changeset}
          user_changeset={@user_changeset}
          steps={@steps}
          step={@step}
          suggestions={@suggestions}
          return_to={@return_to}
        />

        <%!-- After the form, so Enter in a text field still saves. --%>
        <button
          type="submit"
          form="welcome-form"
          name="skip"
          value="1"
          data-welcome-skip
          title={gettext("Close")}
          class="absolute right-3 top-3 flex h-10 w-10 items-center justify-center rounded-full text-slate-600 hover:bg-slate-100 dark:text-slate-400 dark:hover:bg-slate-800"
        >
          <svg class="h-5 w-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24" aria-hidden="true">
            <path stroke-linecap="round" stroke-linejoin="round" d="M6 18 18 6M6 6l12 12" />
          </svg>
          <span class="sr-only">{gettext("Close")}</span>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  One step of the questions, as a form that posts to `/system/welcome`.

  Which step is the caller's business (`Vutuv.Welcome` owns the list): the
  location group posts as `address[...]` through the lax
  `Address.welcome_changeset/2`, the job group as `user[...]` through the
  ordinary `User.changeset/2`, and the suggested accounts as `follow[]`. Every
  step is optional and **saves as it is left**, so the primary button reads
  Weiter until the last one, where it reads Fertig.
  """
  attr(:address_changeset, Ecto.Changeset, required: true)
  attr(:user_changeset, Ecto.Changeset, required: true)
  attr(:steps, :list, required: true, doc: "every step this member gets, in order")
  attr(:step, :atom, required: true, doc: "the one to render now")
  attr(:suggestions, :list, default: [], doc: "`Vutuv.Welcome` structs for the accounts step")

  attr(:return_to, :string,
    default: nil,
    doc: "the page the window floats over, so answering a step does not navigate"
  )

  def welcome_form(assigns) do
    ~H"""
    <% label_class = "block text-sm font-medium text-slate-900 dark:text-white" %>
    <% hint_class = "mt-1 text-sm text-slate-600 dark:text-slate-400" %>
    <% small_label_class = "block text-xs font-medium text-slate-600 dark:text-slate-400" %>
    <% last? = @step == List.last(@steps) %>
    <.form
      :let={f}
      for={@address_changeset}
      as={:address}
      action={~p"/system/welcome"}
      id="welcome-form"
      class="space-y-6"
    >
      <input :if={@return_to} type="hidden" name="return_to" value={@return_to} />
      <%!-- The job group is a second changeset in the same <form>: its inputs are
      built from their own form struct, so they post under user[...]. --%>
      <% uf = to_form(@user_changeset, as: :user) %>
      <% status_set? = Form.input_value(uf, :employment_status) not in [nil, ""] %>
      <.form_error changeset={
        if @address_changeset.action, do: @address_changeset, else: @user_changeset
      } />

      <%!-- How far along, in the one place a wizard that cannot go back owes
      the reader an answer: how much is still coming. Muted and small — it is
      chrome, not a headline. --%>
      <p :if={length(@steps) > 1} class="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
        {gettext("Step %{current} of %{total}",
          current: Enum.find_index(@steps, &(&1 == @step)) + 1,
          total: length(@steps)
        )}
      </p>

      <%!-- Group 1: where you are. Deliberately coarse - no street, and any one
      of the three fields on its own is a complete answer. It opens straight on
      "Type of address" (Stefan, 2026-09-03): a group of address fields needs
      no headline saying they are address fields, and "Where are you?" read as
      an odd thing for a website to ask. --%>
      <section :if={@step == :location} class="space-y-4">
        <fieldset>
          <legend class="mb-1.5 text-sm font-semibold text-slate-700 dark:text-slate-300">
            {gettext("Type of address")}
          </legend>
          <% selected_label = selected_address_label(f) %>
          <div class="flex flex-wrap gap-x-5 gap-y-2">
            <label
              :for={choice <- address_label_options()}
              class={radio_label_class()}
            >
              <%= radio_button f, :description, choice, class: radio_class(), checked: choice == selected_label %>
              <span>{choice}</span>
            </label>
          </div>
          <%= error_tag f, :description %>
        </fieldset>

        <%!-- maxlength mirrors what Address.welcome_changeset/2 allows, so a
        pasted essay is cut here rather than bouncing the whole form. --%>
        <div class="grid gap-4 sm:grid-cols-3">
          <div>
            <%= label f, :zip_code, gettext("Postal code"), class: small_label_class %>
            <%!-- The first field of the first question takes the cursor. --%>
            <%= text_input f, :zip_code, class: input_class(f, :zip_code), autocomplete: "postal-code", autofocus: true, maxlength: "32", "aria-invalid": f.errors[:zip_code] && "true" %>
            <%= error_tag f, :zip_code %>
          </div>
          <div class="sm:col-span-2">
            <%= label f, :city, gettext("City"), class: small_label_class %>
            <%= text_input f, :city, class: input_class(f, :city), autocomplete: "address-level2", maxlength: "100", "aria-invalid": f.errors[:city] && "true" %>
            <%= error_tag f, :city %>
          </div>
        </div>

        <div>
          <%= label f, :country, gettext("Country"), class: small_label_class %>
          <%!-- Localized label, English value — see AddressHTML.country_options/1. --%>
          <%= select f, :country, country_options(Form.input_value(f, :country)), prompt: gettext("Select a Country"), class: input_class() %>
          <%= error_tag f, :country %>
        </div>
      </section>

      <%!-- Group 2: the job search. The salary + workplace panel is revealed only
      once a status is picked (the EmploymentVisibility enhancement in app.js,
      the same one the Basics form uses); with JS off the server-rendered state
      stands, so a member who is not looking never sees the extra fields. --%>
      <section :if={@step == :job} class="space-y-4" data-employment-status-field>
        <h3 class="text-base font-bold text-slate-900 dark:text-white">
          {gettext("Are you looking for a job?")}
        </h3>

        <div>
          <%= label uf, :employment_status, gettext("Availability"), class: label_class %>
          <%= select uf, :employment_status, employment_status_options(), class: input_class(), data: [employment_status_select: true] %>
          <%= error_tag uf, :employment_status %>
        </div>

        <div data-jobsearch-details class={["space-y-5", !status_set? && "hidden"]}>
          <%!-- Who may see the availability. On the Basics form this sits behind
          a longer explanation; here the three options speak for themselves and
          the default ("Signed-in members only") is already selected. --%>
          <div>
            <%= label uf, :employment_status_visibility, gettext("Who can see your availability?"), class: label_class %>
            <%= select uf, :employment_status_visibility, visibility_options(), class: input_class() %>
            <%= error_tag uf, :employment_status_visibility %>
          </div>

          <div>
            <p class="text-sm font-medium text-slate-900 dark:text-white">
              {gettext("Minimum salary expectation")}
            </p>
            <p class={hint_class}>
              {gettext(
                "Optional, and nobody else sees it. It filters postings below it out of your own job search."
              )}
            </p>
            <div class="mt-2 grid gap-3 sm:grid-cols-3">
              <div>
                <%= label uf, :desired_salary_min, gettext("Amount"), class: small_label_class %>
                <%= number_input uf, :desired_salary_min, min: "1", step: "1", placeholder: "60000", class: input_class(uf, :desired_salary_min), "aria-invalid": uf.errors[:desired_salary_min] && "true" %>
              </div>
              <div>
                <%= label uf, :desired_salary_period, gettext("Per"), class: small_label_class %>
                <%= select uf, :desired_salary_period, desired_salary_period_options(), class: input_class() %>
              </div>
              <div>
                <%= label uf, :desired_salary_currency, gettext("Currency"), class: small_label_class %>
                <%= select uf, :desired_salary_currency, desired_salary_currency_options(), class: input_class() %>
              </div>
            </div>
            <%= error_tag uf, :desired_salary_min %>
          </div>

          <%!-- Checkboxes, not a select: on-site, hybrid and remote don't exclude
          each other, and ticking none is the "no preference" answer. The leading
          hidden field is what makes unticking everything reach the server as an
          empty list. --%>
          <fieldset>
            <legend class={label_class}>{gettext("How do you want to work?")}</legend>
            <% chosen = Form.input_value(uf, :desired_workplace_types) || [] %>
            <input type="hidden" name="user[desired_workplace_types][]" value="" />
            <div class="mt-1.5 flex flex-wrap gap-x-5 gap-y-2">
              <label
                :for={{wlabel, wvalue} <- desired_workplace_options()}
                class={radio_label_class()}
              >
                <input
                  type="checkbox"
                  name="user[desired_workplace_types][]"
                  value={wvalue}
                  checked={wvalue in chosen}
                  class={checkbox_class()}
                />
                <span>{wlabel}</span>
              </label>
            </div>
            <p class={hint_class}>
              {gettext("Shown next to your availability, and used to match you with postings.")}
            </p>
            <%= error_tag uf, :desired_workplace_types %>
          </fieldset>
        </div>
      </section>

      <%!-- Step 3: a feed with nothing in it is the first thing a new member
      sees, and "find people to follow" is a chore. Three named accounts are
      one tick each, ticked already, and every one of them can be unfollowed
      from its own page. Which accounts is per installation and per locale —
      see Vutuv.Welcome. The leading hidden field is what makes unticking
      everything reach the server as an empty list. --%>
      <section :if={@step == :accounts} class="space-y-4">
        <h3 class="text-base font-bold text-slate-900 dark:text-white">
          {gettext("Who do you want to follow?")}
        </h3>
        <p class={hint_class}>
          {gettext(
            "Your feed shows what the accounts you follow write. Here are a few to start with; you can unfollow any of them at any time."
          )}
        </p>

        <input type="hidden" name="follow[]" value="" />
        <ul class="space-y-1">
          <li :for={suggestion <- @suggestions}>
            <label class="flex items-center gap-3 rounded-xl p-2 hover:bg-slate-50 dark:hover:bg-slate-800">
              <input
                type="checkbox"
                name="follow[]"
                value={suggestion.address}
                checked
                class={checkbox_class()}
              />
              <.avatar :if={suggestion.user} user={suggestion.user} size="sm" />
              <.remote_avatar
                :if={is_nil(suggestion.user)}
                initials={name_initials(Welcome.label(suggestion))}
                src={suggestion.remote_account && RemoteAccount.avatar_url(suggestion.remote_account)}
                size="sm"
              />
              <span class="min-w-0">
                <span class="block truncate text-sm font-semibold text-slate-900 dark:text-white">
                  {Welcome.label(suggestion)}
                </span>
                <span class="block truncate text-xs text-slate-600 dark:text-slate-400">
                  {suggestion.handle}
                </span>
              </span>
            </label>
          </li>
        </ul>
      </section>

      <div class="flex flex-wrap items-center gap-3 border-t border-slate-200 pt-6 dark:border-slate-800">
        <.button type="submit" id="welcome-save">
          {if last?, do: gettext("Done"), else: gettext("Continue")}
        </.button>
        <.button type="submit" variant="ghost" name="skip" value="1" id="welcome-skip" data-welcome-skip>
          {gettext("Skip for now")}
        </.button>
      </div>
    </.form>
    """
  end

  @doc """
  The hero greeting of the `/system/welcome` **page**: the member's first name
  when they gave one, so it reads as a personal welcome rather than a form.
  Falls back to the plain greeting for an account that only has a last name or
  a nickname. The modal carries no greeting at all — it opens on the question.
  """
  def welcome_title(%User{first_name: name}) when is_binary(name) and name != "",
    do: gettext("Welcome to vutuv, %{name}!", name: name)

  def welcome_title(%User{}), do: gettext("Welcome to vutuv!")

  # The address-label choices. The stored value is the translated word itself,
  # because `addresses.description` is a free-text label everywhere else (the
  # member types their own on /settings/addresses) — no code reads it back.
  defp address_label_options do
    [gettext("Private"), gettext("Work")]
  end

  # Which address label the radio group shows as picked: whatever was
  # submitted, else the first choice ("Private"). Preselecting the everyday
  # case keeps the member from having to answer a question they did not ask
  # for — and the label alone never creates an address
  # (`Address.location_given?/1`).
  defp selected_address_label(form) do
    case Form.input_value(form, :description) do
      value when is_binary(value) and value != "" -> value
      _ -> hd(address_label_options())
    end
  end

  # The country choices, shared with the classic address forms.
  defp country_options(current), do: AddressHTML.country_options(current)
end
