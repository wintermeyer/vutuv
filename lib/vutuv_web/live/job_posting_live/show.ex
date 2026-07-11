defmodule VutuvWeb.JobPostingLive.Show do
  @moduledoc """
  The public job-posting detail page (`/jobs/:slug`, issue #932). Embedded via
  `live_render` from `VutuvWeb.JobPostingController` (off-router, like the
  profile / organization pages); the agent-format siblings stay controller-owned.

  Mobile-first: the employer trust block, the workplace / location / salary
  chips, the Markdown description, the tags split into "Erforderlich" /
  "Wünschenswert" (a signed-in viewer's own matching tags highlighted), the
  apply button and the like / bookmark bar. The like count is live over PubSub;
  a closure or edit updates open tabs.
  """

  use VutuvWeb, :live_view

  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Salary
  alias VutuvWeb.JsonLd
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.UserHelpers

  @impl true
  def mount(_params, session, socket) do
    current_user = InitAssigns.load_user(session["user_id"])
    VutuvWeb.LiveLocale.put_locale(current_user, session)

    posting = Jobs.get_job_posting_by_slug(session["slug"])

    if connected?(socket) do
      Jobs.subscribe(posting.id)
      # Approximate view counting; skip the owner's own visits.
      unless Jobs.owner?(posting, current_user), do: Jobs.increment_view(posting)
    end

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:locale, session["locale"])
      |> assign(:shell_path, session["request_path"])
      |> assign_posting(posting, current_user)

    {:ok, socket}
  end

  defp assign_posting(socket, posting, viewer) do
    socket
    |> assign(:posting, posting)
    |> assign(:page_title, posting.title)
    |> assign(:owner?, Jobs.owner?(posting, viewer))
    |> assign(:effective_status, Jobs.effective_status(posting))
    |> assign(:engagement, Jobs.job_posting_engagement(posting, viewer))
    |> assign(:matching_tags, Jobs.matching_tag_slugs(posting, viewer))
  end

  @impl true
  def handle_event("toggle_like", _params, socket), do: {:noreply, toggle(socket, :like)}

  def handle_event("toggle_bookmark", _params, socket), do: {:noreply, toggle(socket, :bookmark)}

  defp toggle(%{assigns: %{current_user: nil}} = socket, _kind),
    do: push_navigate(socket, to: ~p"/login")

  defp toggle(socket, kind) do
    %{current_user: user, posting: posting, engagement: engagement} = socket.assigns
    apply_engagement(kind, user, posting, engagement)
    assign(socket, :engagement, Jobs.job_posting_engagement(posting, user))
  end

  defp apply_engagement(:like, user, posting, %{liked?: true}),
    do: Jobs.unlike_job_posting(user, posting)

  defp apply_engagement(:like, user, posting, _), do: Jobs.like_job_posting(user, posting)

  defp apply_engagement(:bookmark, user, posting, %{bookmarked?: true}),
    do: Jobs.unbookmark_job_posting(user, posting)

  defp apply_engagement(:bookmark, user, posting, _), do: Jobs.bookmark_job_posting(user, posting)

  @impl true
  def handle_info({:job_posting_counters, %{likes: likes}}, socket) do
    {:noreply, assign(socket, :engagement, %{socket.assigns.engagement | likes: likes})}
  end

  def handle_info({:job_posting_updated, _}, socket) do
    posting = Jobs.get_job_posting_by_slug(socket.assigns.posting.slug)
    {:noreply, assign_posting(socket, posting, socket.assigns.current_user)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <JsonLd.script :if={Jobs.indexable?(@posting)} data={JsonLd.job_posting(@posting)} />

    <div class="grid gap-6 py-6 md:grid-cols-3">
      <div class="min-w-0 space-y-6 md:col-span-2">
        <.frozen_banner :if={@owner? and @posting.frozen_at} class="rounded-2xl px-4 py-3 text-sm">
          {gettext("Only you can see this posting while a report about it is handled.")}
        </.frozen_banner>

        <div
          :if={@effective_status in [:expired, :closed]}
          class="rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-800 ring-1 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200"
        >
          {gettext("This position is no longer available.")}
        </div>

        <.card class="space-y-5">
          <div>
            <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{@posting.title}</h1>
            <.employer_block posting={@posting} />
          </div>

          <div class="flex flex-wrap gap-2">
            <.chip>{JobPosting.employment_type_label(@posting.employment_type)}</.chip>
            <.chip>{JobPosting.workplace_type_label(@posting.workplace_type)}</.chip>
            <.chip :if={location_line(@posting)}>{location_line(@posting)}</.chip>
          </div>

          <p class="text-lg font-semibold text-slate-900 dark:text-slate-100">
            {salary_display(@posting)}
          </p>

          <div class="flex flex-wrap items-center gap-3">
            <.form
              for={to_form(%{}, as: :apply)}
              action={~p"/jobs/#{@posting.slug}/apply"}
              method="post"
            >
              <button
                type="submit"
                class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
              >
                {apply_label(@posting)}
              </button>
            </.form>

            <button
              type="button"
              phx-click="toggle_like"
              aria-pressed={@engagement.liked?}
              class={[
                "flex items-center gap-1.5 text-sm font-medium",
                @engagement.liked? && "text-accent"
              ]}
            >
              <.icon_heart filled?={@engagement.liked?} class="h-5 w-5" />
              <span class="tabular-nums">{compact_count(@engagement.likes)}</span>
              <span class="sr-only">{gettext("Like")}</span>
            </button>

            <button
              type="button"
              phx-click="toggle_bookmark"
              aria-pressed={@engagement.bookmarked?}
              class={[
                "flex items-center gap-1.5 text-sm font-medium",
                @engagement.bookmarked? && "text-brand-600 dark:text-brand-300"
              ]}
            >
              <.icon_bookmark filled?={@engagement.bookmarked?} class="h-5 w-5" />
              <span class="sr-only">{gettext("Bookmark")}</span>
            </button>
          </div>

          <p class="text-xs text-slate-600 dark:text-slate-400">
            <span :if={@posting.first_published_at}>
              {gettext("Posted")}: <.local_time at={@posting.first_published_at} id="posted" format="%Y-%m-%d" />
            </span>
            <span :if={@posting.expires_on}>
              · {gettext("Expires")}: {Calendar.strftime(@posting.expires_on, "%Y-%m-%d")}
            </span>
          </p>
        </.card>

        <.card :if={@posting.description && @posting.description != ""}>
          <div class="markdown markdown--post text-slate-800 dark:text-slate-200">
            {raw(VutuvWeb.Markdown.render_post(@posting.description, []))}
          </div>
        </.card>

        <.card :if={has_tags?(@posting)} class="space-y-4">
          <.tag_group
            title={gettext("Required")}
            tags={Jobs.tags_of(@posting, :required)}
            matching={@matching_tags}
          />
          <.tag_group
            title={gettext("Nice to have")}
            tags={Jobs.tags_of(@posting, :nice_to_have)}
            matching={@matching_tags}
          />
          <p :if={@current_user && MapSet.size(@matching_tags) > 0} class="text-xs text-emerald-700 dark:text-emerald-400">
            {gettext("Highlighted tags match your profile.")}
          </p>
        </.card>

        <p class="text-xs">
          <.link
            :if={@current_user && not @owner?}
            href={~p"/reports/new?#{[type: "job_posting", id: @posting.id, return_to: "/jobs/#{@posting.slug}"]}"}
            class="text-slate-600 hover:text-slate-800 dark:text-slate-400"
          >
            {gettext("Report this posting")}
          </.link>
        </p>
      </div>

      <aside class="space-y-4">
        <.card :if={@owner?} class="space-y-2 text-sm">
          <p class="font-semibold text-slate-900 dark:text-slate-100">{gettext("Your posting")}</p>
          <.link navigate={~p"/jobs/#{@posting.slug}/edit"} class="block text-brand-600 hover:text-brand-700">
            {gettext("Edit")}
          </.link>
          <.link navigate={~p"/jobs/mine"} class="block text-brand-600 hover:text-brand-700">
            {gettext("My postings")}
          </.link>
        </.card>

        <.other_formats_card
          base_path={"/jobs/" <> @posting.slug}
          locale={@locale}
          machine_formats={@posting.geo?}
        />
      </aside>
    </div>
    """
  end

  # --- render helpers --------------------------------------------------------

  attr(:posting, :map, required: true)

  defp employer_block(assigns) do
    ~H"""
    <div class="mt-2 flex items-center gap-2 text-sm">
      <%= if @posting.organization do %>
        <.link
          navigate={Vutuv.Organizations.canonical_path(@posting.organization)}
          class="font-semibold text-brand-700 hover:text-brand-800 dark:text-brand-300"
        >
          {@posting.organization.name}
        </.link>
        <.verified_mark title={gettext("Verified organization")} />
      <% else %>
        <.link navigate={"/" <> @posting.user.username} class="flex items-center gap-2">
          <.avatar user={@posting.user} size="xs" shape="circle" />
          <span class="font-semibold text-slate-900 dark:text-slate-100">
            {UserHelpers.full_name(@posting.user)}
          </span>
        </.link>
        <span :if={@posting.hiring_org_name} class="text-slate-600 dark:text-slate-400">
          · {@posting.hiring_org_name}
        </span>
      <% end %>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:tags, :list, required: true)
  attr(:matching, :any, required: true)

  defp tag_group(assigns) do
    ~H"""
    <div :if={@tags != []}>
      <.section_title>{@title}</.section_title>
      <div class="mt-2 flex flex-wrap gap-2">
        <.link
          :for={tag <- @tags}
          navigate={~p"/tags/#{tag.slug}"}
          class={[
            "inline-flex items-center rounded-lg px-3 py-1.5 text-sm font-medium",
            if(MapSet.member?(@matching, tag.slug),
              do: "bg-emerald-100 text-emerald-800 ring-1 ring-emerald-300 dark:bg-emerald-900/40 dark:text-emerald-100",
              else: "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
            )
          ]}
        >
          {tag.name}
        </.link>
      </div>
    </div>
    """
  end

  defp has_tags?(posting) do
    Jobs.tags_of(posting, :required) != [] or Jobs.tags_of(posting, :nice_to_have) != []
  end

  defp location_line(%{workplace_type: :remote}), do: nil

  defp location_line(%{zip_code: zip, city: city, country: country}) do
    [[zip, city] |> Enum.reject(&blank?/1) |> Enum.join(" "), Vutuv.Countries.name(country)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
    |> case do
      "" -> nil
      line -> line
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp salary_display(%JobPosting{employment_type: :volunteer}), do: gettext("Voluntary")

  defp salary_display(%JobPosting{salary_min: nil}), do: gettext("Salary on request")

  defp salary_display(%JobPosting{} = posting) do
    Salary.range_label(
      posting.salary_min,
      posting.salary_max,
      posting.salary_currency,
      posting.salary_period,
      &delimited_count/1
    )
  end

  defp apply_label(%JobPosting{apply_kind: :url}), do: gettext("Apply on website")
  defp apply_label(%JobPosting{apply_kind: :email}), do: gettext("Apply by e-mail")
  defp apply_label(%JobPosting{apply_kind: :message}), do: gettext("Message the poster")
end
