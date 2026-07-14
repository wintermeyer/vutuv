defmodule VutuvWeb.JobExclusionComponents do
  @moduledoc """
  The shared job-offer exclusion editor (issue #939), rendered identically by the
  per-posting editor (`VutuvWeb.JobPostingLive.Exclusions`) and the organization
  standing-default editor (`VutuvWeb.OrganizationLive.Exclusions`). Both hosts
  build the same three add forms (member / organization / email domain) and the
  "currently excluded" list; each host owns the four events the panel emits —
  `add_member`, `add_organization`, `add_domain` and `remove` — and calls the
  matching `Vutuv.Jobs.Exclusions` function for its own subject. DRY, so the two
  sides of the list can never drift.
  """
  use VutuvWeb, :html

  import VutuvWeb.ErrorHelpers

  alias VutuvWeb.UserHelpers

  attr(:member_form, :any, required: true)
  attr(:member_error, :string, default: nil)
  attr(:org_form, :any, required: true)
  attr(:org_error, :string, default: nil)
  attr(:domain_form, :any, required: true)
  attr(:exclusions, :list, required: true)

  @doc "The three add forms plus the currently-excluded list."
  def exclusion_panel(assigns) do
    ~H"""
    <div class="space-y-6">
      <.card>
        <.section_title>{gettext("Exclude a member")}</.section_title>
        <.form
          for={@member_form}
          id="exclude-member-form"
          phx-submit="add_member"
          class="mt-3 flex flex-wrap items-start gap-2"
        >
          <div class="min-w-0 flex-1">
            <input
              type="text"
              name="member[handle]"
              value={@member_form[:handle].value}
              placeholder="@username"
              autocomplete="off"
              aria-label={gettext("Member @handle")}
              aria-invalid={@member_error && "true"}
              class={input_class(!!@member_error)}
            />
            <p :if={@member_error} class="editform__error mt-1" id="member-error">{@member_error}</p>
          </div>
          <.button type="submit">{gettext("Exclude")}</.button>
        </.form>
      </.card>

      <.card>
        <.section_title>{gettext("Exclude an organization")}</.section_title>
        <.form
          for={@org_form}
          id="exclude-organization-form"
          phx-submit="add_organization"
          class="mt-3 flex flex-wrap items-start gap-2"
        >
          <div class="min-w-0 flex-1">
            <input
              type="text"
              name="organization[handle]"
              value={@org_form[:handle].value}
              placeholder="@organization"
              autocomplete="off"
              aria-label={gettext("Organization @handle")}
              aria-invalid={@org_error && "true"}
              class={input_class(!!@org_error)}
            />
            <p :if={@org_error} class="editform__error mt-1" id="organization-error">{@org_error}</p>
          </div>
          <.button type="submit">{gettext("Exclude")}</.button>
        </.form>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "Excluding an organization also hides the posting from its verified email domains, its team, and members whose current job is linked to it."
          )}
        </p>
      </.card>

      <.card>
        <.section_title>{gettext("Exclude an email domain")}</.section_title>
        <.form
          for={@domain_form}
          id="exclude-domain-form"
          phx-submit="add_domain"
          class="mt-3 flex flex-wrap items-start gap-2"
        >
          <div class="min-w-0 flex-1">
            <input
              type="text"
              name="domain[domain]"
              value={@domain_form[:domain].value}
              placeholder="example.com"
              autocomplete="off"
              aria-label={gettext("Email domain")}
              aria-invalid={@domain_form[:domain].errors != [] && "true"}
              class={input_class(@domain_form, :domain)}
            />
            {error_tag(@domain_form, :domain)}
          </div>
          <.button type="submit">{gettext("Exclude")}</.button>
        </.form>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "Any signed-in member whose confirmed email is at this domain, or a subdomain of it, is excluded."
          )}
        </p>
      </.card>

      <.card>
        <.section_title>
          {gettext("Currently excluded")} ({compact_count(length(@exclusions))})
        </.section_title>

        <p :if={@exclusions == []} class="mt-3 text-sm text-slate-600 dark:text-slate-400">
          {gettext("This list is empty. Nobody is excluded yet.")}
        </p>

        <ul
          :if={@exclusions != []}
          id="exclusion-list"
          class="mt-3 divide-y divide-slate-100 dark:divide-slate-800"
        >
          <li
            :for={x <- @exclusions}
            id={"exclusion-#{x.id}"}
            class="flex items-center justify-between gap-3 py-3"
          >
            <div class="flex min-w-0 items-center gap-3">
              <%= cond do %>
                <% x.excluded_user -> %>
                  <.avatar user={x.excluded_user} size="xs" shape="circle" />
                  <div class="min-w-0">
                    <.link
                      navigate={~p"/#{x.excluded_user}"}
                      class="block truncate font-medium text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"
                    >
                      {UserHelpers.full_name(x.excluded_user)}
                    </.link>
                    <span class="block truncate text-sm text-slate-600 dark:text-slate-400">
                      @{x.excluded_user.username}
                    </span>
                  </div>
                <% x.excluded_organization -> %>
                  <span
                    aria-hidden="true"
                    class="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400"
                  >
                    ⌂
                  </span>
                  <div class="min-w-0">
                    <.link
                      navigate={~p"/organizations/#{x.excluded_organization.slug}"}
                      class="block truncate font-medium text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"
                    >
                      {x.excluded_organization.name}
                    </.link>
                    <span class="block text-sm text-slate-600 dark:text-slate-400">
                      {gettext("Organization")}
                    </span>
                  </div>
                <% true -> %>
                  <span
                    aria-hidden="true"
                    class="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400"
                  >
                    @
                  </span>
                  <div class="min-w-0">
                    <span class="block truncate font-medium text-slate-900 dark:text-white">
                      {x.domain}
                    </span>
                    <span class="block text-sm text-slate-600 dark:text-slate-400">
                      {gettext("Email domain")}
                    </span>
                  </div>
              <% end %>
            </div>
            <button
              type="button"
              phx-click="remove"
              phx-value-id={x.id}
              class="shrink-0 text-sm font-semibold text-red-600 hover:text-red-700 dark:text-red-400 dark:hover:text-red-300"
            >
              {gettext("Remove")}
            </button>
          </li>
        </ul>
      </.card>
    </div>
    """
  end
end
