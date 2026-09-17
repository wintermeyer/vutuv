defmodule VutuvWeb.InvestorsReachLive do
  @moduledoc """
  The yearly reach card on `/system/investors`: the potential repost reach of
  every public post published this year (`Vutuv.PostAnalytics.Year`), with the
  steps that produce it shown as they finish.

  Embedded via `live_render` from the investor page's template, so the
  controller keeps serving the agent-format siblings, which read the same
  figure through `Vutuv.PostAnalytics.YearRunner.fetch/1`.

  **The steps are the point, not decoration.** A whole-year aggregate is the
  one figure on that page a reader cannot check against a count they can see,
  so the card says what it adds up while it adds it up, and keeps the list,
  with each step's figures and duration, once it is done. The run itself
  belongs to `YearRunner`, which every open card watches: a reader arriving
  mid-run sees the steps already finished and hears the rest.

  The dead render starts nothing (`YearRunner.peek/1`): a crawler requesting
  the page must not set off an aggregate. It shows the last result when there
  is one and the steps waiting otherwise. Without a runner (tests) the
  connected view computes in its own process through `start_async/3`.
  """

  use VutuvWeb, :live_view

  alias Vutuv.PostAnalytics.Year
  alias Vutuv.PostAnalytics.YearRunner
  alias VutuvWeb.AgentDocs.InvestorsDoc
  alias VutuvWeb.CompanyHTML
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> InitAssigns.assign_embedded(session)
      |> assign(failed?: false)

    if connected?(socket) do
      case YearRunner.watch() do
        :no_runner -> {:ok, socket |> assign_snapshot(nil, [], true) |> compute_here()}
        snapshot -> {:ok, assign_snapshot(socket, snapshot)}
      end
    else
      {:ok, assign_snapshot(socket, YearRunner.peek())}
    end
  end

  @impl true
  def handle_info({:year_reach, :started}, socket) do
    {:noreply, assign(socket, steps: [], running?: true, failed?: false)}
  end

  # Keyed rather than appended: a step broadcast in the moment between
  # subscribing and asking the runner arrives twice.
  def handle_info({:year_reach, {:step, step}}, socket) do
    steps = Enum.reject(socket.assigns.steps, &(&1.key == step.key)) ++ [step]
    {:noreply, assign(socket, steps: steps)}
  end

  def handle_info({:year_reach, {:done, result}}, socket) do
    {:noreply, assign_snapshot(socket, result, [], false)}
  end

  def handle_info({:year_reach, :failed}, socket) do
    {:noreply, assign(socket, running?: false, failed?: true, steps: [])}
  end

  # The in-process run ends the way a runner's run does.
  @impl true
  def handle_async(:year_reach, {:ok, result}, socket),
    do: handle_info({:year_reach, {:done, result}}, socket)

  def handle_async(:year_reach, {:exit, _reason}, socket),
    do: handle_info({:year_reach, :failed}, socket)

  defp compute_here(socket) do
    view = self()

    start_async(socket, :year_reach, fn ->
      Year.compute(progress: &send(view, {:year_reach, {:step, &1}}))
    end)
  end

  defp assign_snapshot(socket, %{result: result, steps: steps, running?: running?}),
    do: assign_snapshot(socket, result, steps, running?)

  defp assign_snapshot(socket, result, steps, running?) do
    assign(socket,
      result: result,
      steps: steps,
      running?: running?,
      year: if(result, do: result.year, else: DateTime.utc_now().year)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.card>
      <h2 class="text-xl font-bold text-slate-900 dark:text-white">
        {gettext("Reach in %{year}", year: @year)}
      </h2>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {InvestorsDoc.year_reach_lead()}
      </p>
      <.error_banner :if={@failed?} class="mt-4">
        {gettext("The calculation failed. Reload the page to try again.")}
      </.error_banner>

      <div class="mt-5 grid gap-6 lg:grid-cols-2">
        <div class="min-w-0">
          <%= if @result do %>
            <.section_title>{gettext("Potential reach from reposts")}</.section_title>
            <p
              data-year-reach-total={@result.reach.known}
              class="mt-1 mb-0 text-5xl font-bold tracking-tight tabular-nums text-slate-900 dark:text-white"
            >
              {delimited_count(@result.reach.known)}<span class="text-accent">+</span>
            </p>
            <p class="mt-1 mb-0 text-xs text-slate-600 dark:text-slate-400">
              {gettext("%{known} known · %{unknown} unavailable",
                known: delimited_count(@result.reach.known_reposters),
                unknown: delimited_count(@result.reach.unknown_reposters)
              )}
            </p>
            <.month_bars months={@result.months} />
            <%!-- Two columns on a phone: three tiles side by side leave a
                  German label like "Öffentliche Beiträge" no room and clip it. --%>
            <div class="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-3">
              <CompanyHTML.figure_tile
                label={gettext("Public posts")}
                value={delimited_count(@result.posts)}
              />
              <CompanyHTML.figure_tile
                label={gettext("Interactions")}
                value={delimited_count(@result.totals.all)}
              />
              <div class="col-span-2 sm:col-span-1">
                <CompanyHTML.figure_tile
                  label={gettext("Fediverse servers")}
                  value={delimited_count(@result.servers.all)}
                />
              </div>
            </div>
          <% else %>
            <%!-- A placeholder the size of the figure, so the card does not
                  jump when it arrives. --%>
            <div class="flex h-full min-h-48 items-center justify-center rounded-xl bg-slate-50 p-6 text-center dark:bg-slate-800/60">
              <p :if={not @failed?} class="mb-0 text-sm text-slate-600 dark:text-slate-400">
                {gettext("The figure appears here once the steps beside it are done.")}
              </p>
            </div>
          <% end %>
        </div>

        <div class="min-w-0">
          <.section_title>
            {if @running?,
              do: gettext("Working it out in the background"),
              else: gettext("How the figure came about")}
          </.section_title>
          <ol class="mt-3 space-y-3">
            <li
              :for={row <- step_rows(@result, @steps, @running?)}
              data-year-reach-step={row.key}
              data-state={row.state}
              class="flex items-start gap-3"
            >
              <.step_marker state={row.state} />
              <div class="min-w-0 flex-1">
                <p class={[
                  "mb-0 text-sm font-medium",
                  if(row.state == :waiting,
                    do: "text-slate-600 dark:text-slate-400",
                    else: "text-slate-900 dark:text-white"
                  )
                ]}>
                  {step_label(row.key)}
                </p>
                <p :if={row.step} class="mt-0.5 mb-0 text-xs text-slate-600 dark:text-slate-400">
                  {step_summary(row.step)}
                </p>
              </div>
              <span
                :if={row.step}
                class="shrink-0 text-xs tabular-nums text-slate-600 dark:text-slate-400"
              >
                {duration(row.step.ms)}
              </span>
            </li>
          </ol>
          <p :if={@result && not @running?} class="mt-3 text-xs text-slate-600 dark:text-slate-400">
            {gettext("Calculated %{when}", when: relative_time(@result.computed_at))}
          </p>
        </div>
      </div>

      <details class="mt-6 border-t border-slate-200 pt-4 text-sm dark:border-slate-700">
        <summary class="cursor-pointer font-medium text-slate-900 dark:text-white">
          {gettext("How this is calculated")}
        </summary>
        <div class="mt-3 max-w-3xl space-y-2 text-slate-600 dark:text-slate-400">
          <p :for={sentence <- InvestorsDoc.year_reach_explainer()} class="mb-0">{sentence}</p>
        </div>
      </details>
    </.card>
    """
  end

  attr(:months, :list, required: true)

  # The reach each month's posts brought, as bars on a linear scale: a month
  # that stands out should look like it does. The figure sits above each bar,
  # so the chart needs no axis.
  defp month_bars(assigns) do
    assigns =
      assign(assigns, :peak, assigns.months |> Enum.map(& &1.reach) |> Enum.max(fn -> 0 end))

    ~H"""
    <figure :if={@peak > 0} class="mt-5">
      <figcaption class="text-xs text-slate-600 dark:text-slate-400">
        {gettext("By month of publication")}
      </figcaption>
      <div class="mt-2 flex h-36 items-end gap-1.5">
        <div
          :for={month <- @months}
          data-year-reach-month={month.month}
          title={"#{month_name(month.month)}: #{delimited_count(month.reach)}"}
          class="flex h-full min-w-0 flex-1 flex-col items-center justify-end gap-1"
        >
          <span
            :if={month.reach > 0}
            class="text-[10px] font-semibold tabular-nums text-slate-700 dark:text-slate-300"
          >
            {compact_count(month.reach)}
          </span>
          <div
            class="w-full rounded-t bg-brand-600 dark:bg-brand-400"
            style={"height: #{bar_height(month.reach, @peak)}%"}
          >
          </div>
          <span class="text-[10px] text-slate-600 dark:text-slate-400">
            {String.slice(month_name(month.month), 0, 3)}
          </span>
        </div>
      </div>
    </figure>
    """
  end

  # A month with any reach keeps a visible stub, and the tallest bar leaves room
  # for its label and the month name under it.
  defp bar_height(0, _peak), do: 0
  defp bar_height(reach, peak), do: max(2, round(reach / peak * 70))

  attr(:state, :atom, required: true)

  defp step_marker(%{state: :done} = assigns) do
    ~H"""
    <span class="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-brand-600 text-[11px] font-bold text-white dark:bg-brand-500">
      <span aria-hidden="true">✓</span>
      <span class="sr-only">{gettext("Done")}</span>
    </span>
    """
  end

  defp step_marker(%{state: :running} = assigns) do
    ~H"""
    <span class="mt-0.5 h-5 w-5 shrink-0 animate-spin rounded-full border-2 border-brand-600 border-t-transparent motion-reduce:animate-none dark:border-brand-400 dark:border-t-transparent">
      <span class="sr-only">{gettext("Running")}</span>
    </span>
    """
  end

  defp step_marker(assigns) do
    ~H"""
    <span class="mt-0.5 h-5 w-5 shrink-0 rounded-full border-2 border-slate-300 dark:border-slate-600">
      <span class="sr-only">{gettext("Waiting")}</span>
    </span>
    """
  end

  # One row per step in run order. Finished steps come from the run in flight,
  # or from the result once there is no run; the first unfinished step of a
  # running calculation is the one being worked on.
  defp step_rows(result, steps, running?) do
    done = if running? or is_nil(result), do: steps, else: result.steps
    by_key = Map.new(done, &{&1.key, &1})
    current = if running?, do: Enum.find(Year.steps(), &(not Map.has_key?(by_key, &1)))

    for key <- Year.steps() do
      step = Map.get(by_key, key)

      state =
        cond do
          step -> :done
          key == current -> :running
          true -> :waiting
        end

      %{key: key, state: state, step: step}
    end
  end

  defp step_label(:posts), do: gettext("This year's public posts")
  defp step_label(:local_reposts), do: gettext("Followers of members and pages here who reposted")

  defp step_label(:remote_reposts),
    do: gettext("Known followers of Fediverse accounts that reposted")

  defp step_label(:interactions), do: gettext("Likes, reposts and replies")
  defp step_label(:servers), do: gettext("Fediverse servers involved")

  defp step_summary(%{key: :posts, count: count}),
    do:
      ngettext("%{formatted} post", "%{formatted} posts", count,
        formatted: delimited_count(count)
      )

  defp step_summary(%{reposts: reposts, followers: followers, unknown: unknown}) do
    [
      ngettext("%{formatted} repost", "%{formatted} reposts", reposts,
        formatted: delimited_count(reposts)
      ),
      ngettext("%{formatted} follower", "%{formatted} followers", followers,
        formatted: delimited_count(followers)
      ),
      unknown > 0 &&
        gettext("%{formatted} without a known total", formatted: delimited_count(unknown))
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp step_summary(%{key: :interactions, count: count}) do
    ngettext("%{formatted} interaction", "%{formatted} interactions", count,
      formatted: delimited_count(count)
    )
  end

  defp step_summary(%{key: :servers, count: count, responded: responded}) do
    Enum.join(
      [
        ngettext("%{formatted} server", "%{formatted} servers", count,
          formatted: delimited_count(count)
        ),
        gettext("%{formatted} of them responded", formatted: delimited_count(responded))
      ],
      " · "
    )
  end
end
