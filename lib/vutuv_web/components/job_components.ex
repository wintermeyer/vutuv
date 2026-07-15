defmodule VutuvWeb.JobComponents do
  @moduledoc """
  The shared job-posting **card** (issue #933), rendered by the public board
  (`VutuvWeb.JobBoardLive`), the organization page's "Offene Stellen" section
  and the tag page's. One layout everywhere: title, the employer trust block
  (verified organization badge or poster name, same UI as the detail page),
  employment / workplace / location / salary chips, the posting's tags with a
  signed-in viewer's own tags highlighted, and the age ("vor 3 Tagen").

  The like / bookmark action bar renders only when an `engagement` map is
  passed (the board), driven by the enclosing LiveView's `phx-click` events —
  the in-process pattern, no per-card nested LiveView. Dead-page callers (the
  tag page) omit it and the card links to the detail page.

  Not globally imported — `import VutuvWeb.JobComponents` at the call site.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  import VutuvWeb.UI

  alias Vutuv.BerlinTime
  alias Vutuv.Countries
  alias Vutuv.Geo
  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Organizations
  alias Vutuv.Salary
  alias VutuvWeb.UserHelpers

  attr(:posting, :map, required: true)
  attr(:viewer_tags, :any, default: nil, doc: "MapSet of the viewer's tag slugs, highlighted")
  attr(:engagement, :map, default: nil, doc: "%{likes:, liked?:, bookmarked?:} → live action bar")
  attr(:class, :string, default: nil)

  @doc "One job-posting card. Pass `engagement` to render the live like/bookmark bar."
  def job_card(assigns) do
    assigns = assign(assigns, :viewer_tags, assigns.viewer_tags || MapSet.new())

    ~H"""
    <article class={[
      "rounded-2xl bg-white p-5 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800",
      @class
    ]}>
      <div class="flex items-start justify-between gap-3">
        <h3 class="min-w-0 text-lg font-semibold text-slate-900 dark:text-slate-100">
          <.link navigate={~p"/jobs/#{@posting.slug}"} class="hover:text-brand-700 dark:hover:text-brand-300">
            {@posting.title}
          </.link>
        </h3>
        <span class="shrink-0 text-xs text-slate-600 dark:text-slate-400">{job_age(@posting)}</span>
      </div>

      <.employer_line posting={@posting} />

      <div class="mt-3 flex flex-wrap gap-2">
        <.chip>{JobPosting.employment_type_label(@posting.employment_type)}</.chip>
        <.chip>{JobPosting.workplace_type_label(@posting.workplace_type)}</.chip>
        <.chip :if={card_location(@posting)}>{card_location(@posting)}</.chip>
      </div>

      <p class="mt-3 text-sm font-semibold text-slate-900 dark:text-slate-100">
        {salary_line(@posting)}
      </p>

      <div :if={tag_list(@posting) != []} class="mt-3 flex flex-wrap gap-1.5">
        <.link
          :for={tag <- tag_list(@posting)}
          navigate={~p"/jobs?#{[tag: tag.slug]}"}
          class={[
            "inline-flex items-center rounded-lg px-2.5 py-1 text-xs font-medium",
            if(MapSet.member?(@viewer_tags, tag.slug),
              do:
                "bg-emerald-100 text-emerald-800 ring-1 ring-emerald-300 dark:bg-emerald-900/40 dark:text-emerald-100",
              else: "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
            )
          ]}
        >
          {tag.name}
        </.link>
      </div>

      <div :if={@engagement} class="mt-4 flex items-center gap-4">
        <.engagement_bar engagement={@engagement} value_id={@posting.id} />
      </div>
    </article>
    """
  end

  attr(:posting, :map, required: true)

  defp employer_line(assigns) do
    ~H"""
    <div class="mt-1.5 flex flex-wrap items-center gap-1.5 text-sm">
      <%= if @posting.organization do %>
        <.link
          navigate={Organizations.canonical_path(@posting.organization)}
          class="font-semibold text-brand-700 hover:text-brand-800 dark:text-brand-300"
        >
          {@posting.organization.name}
        </.link>
        <.verified_mark title={gettext("Verified organization")} />
      <% else %>
        <span class="font-medium text-slate-700 dark:text-slate-300">{employer_name(@posting)}</span>
      <% end %>
    </div>
    """
  end

  # --- display helpers (shared with the detail page semantics) --------------

  defp employer_name(%JobPosting{hiring_org_name: name}) when is_binary(name) and name != "",
    do: name

  defp employer_name(%JobPosting{user: %{} = user}), do: UserHelpers.full_name(user)
  defp employer_name(_posting), do: nil

  @doc false
  def tag_list(%JobPosting{} = posting) do
    Jobs.tags_of(posting, :required) ++ Jobs.tags_of(posting, :nice_to_have)
  end

  @doc "The card's location chip: 'City, Country' (country only when it differs from the default) or 'Remote (DE, AT)'."
  def card_location(%JobPosting{workplace_type: :remote} = posting) do
    case posting.remote_countries do
      [] -> gettext("Remote")
      codes -> gettext("Remote") <> " (" <> Enum.join(codes, ", ") <> ")"
    end
  end

  def card_location(%JobPosting{city: city, country: country}) do
    parts =
      [city, country_suffix(country)]
      |> Enum.reject(&(&1 in [nil, ""]))

    case parts do
      [] -> nil
      list -> Enum.join(list, ", ")
    end
  end

  defp country_suffix(country) do
    if country in [nil, "", Geo.default_country()], do: nil, else: Countries.name(country)
  end

  @doc "The card's pay line: the range, 'Ehrenamtlich' for a volunteer posting, or nothing."
  def salary_line(%JobPosting{employment_type: :volunteer}), do: gettext("Voluntary")
  def salary_line(%JobPosting{salary_min: nil}), do: gettext("Salary on request")

  def salary_line(%JobPosting{} = posting) do
    Salary.range_label(
      posting.salary_min,
      posting.salary_max,
      posting.salary_currency,
      posting.salary_period,
      &delimited_count/1
    )
  end

  @doc "A short, localized posting age: today, or 'vor N Tagen' (up to the 90-day runtime)."
  def job_age(%JobPosting{first_published_at: nil}), do: nil

  def job_age(%JobPosting{first_published_at: at}) do
    days = Date.diff(BerlinTime.today(), NaiveDateTime.to_date(at))

    cond do
      days <= 0 -> gettext("Today")
      days < 7 -> ngettext("%{count} day ago", "%{count} days ago", days)
      days < 30 -> ngettext("%{count} week ago", "%{count} weeks ago", div(days, 7))
      true -> ngettext("%{count} month ago", "%{count} months ago", div(days, 30))
    end
  end
end
