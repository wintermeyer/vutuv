defmodule VutuvWeb.Admin.ModerationCaseLive do
  @moduledoc """
  One admin moderation case (`/admin/moderation/:id`): the owner, the evidence as
  it looked at report time, every report with the reporter's track record, the
  audit log, and the ruling. Upholding strikes the owner and keeps the content
  frozen; rejecting unfreezes it and (optionally) marks reports abusive, striking
  those reporters. Both rulings act **reload-free** over the socket and then drop
  back to the queue with a toast. The classic CSRF POSTs
  (`ModerationController.uphold/reject`) stay as the no-JS / scriptable fallback.
  Lives in the `:admin` live_session.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.UserHelpers, only: [full_name: 1]

  import VutuvWeb.Admin.ModerationHTML,
    only: [
      status_badge: 1,
      status_tone: 1,
      content_type_label: 1,
      category_label: 1,
      event_label: 1,
      event_detail: 2
    ]

  alias Vutuv.{Chat, Moderation}
  alias Vutuv.Moderation.Case

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Moderation.get_case_with_details(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("This case no longer exists."))
         |> redirect(to: ~p"/admin/moderation")}

      case_record ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Moderation case"))
         |> assign_case(case_record)}
    end
  end

  @impl true
  def handle_event("uphold", _params, socket) do
    rule(socket, &Moderation.uphold_case(&1, socket.assigns.current_user),
      ok: gettext("Report upheld; the owner got a strike.")
    )
  end

  def handle_event("reject", params, socket) do
    abusive_ids = params |> Map.get("abusive_report_ids", []) |> List.wrap()

    rule(socket, &Moderation.reject_case(&1, socket.assigns.current_user, abusive_ids),
      ok: gettext("Report rejected; the content is visible again.")
    )
  end

  # The decisive spam/abuse rulings: remove the account outright, skipping the
  # warn-first strike ladder. Deactivate is reversible from the member browser;
  # delete is permanent (and erases the case, so we just drop back to the queue).
  def handle_event("remove", %{"action" => "deactivate"}, socket) do
    rule(socket, &Moderation.remove_owner(&1, socket.assigns.current_user, :deactivate),
      ok:
        gettext(
          "Account deactivated and marked as spam. Restore it from the member browser if this was wrong."
        )
    )
  end

  def handle_event("remove", %{"action" => "delete"}, socket) do
    rule(socket, &Moderation.remove_owner(&1, socket.assigns.current_user, :delete),
      ok: gettext("Account deleted.")
    )
  end

  # The two rulings share the same shape: apply, flash, drop back to the queue.
  # A ruling on a case someone else already settled flashes the conflict instead.
  defp rule(socket, ruling, ok: message) do
    socket =
      case ruling.(socket.assigns.case) do
        {:ok, _} ->
          put_flash(socket, :info, message)

        {:error, :not_open} ->
          put_flash(socket, :error, gettext("This case has already been resolved."))
      end

    {:noreply, push_navigate(socket, to: ~p"/admin/moderation")}
  end

  defp assign_case(socket, case_record) do
    stats_by_reporter =
      Moderation.reporter_stats_map(Enum.map(case_record.reports, & &1.reporter_id))

    content = Moderation.case_content(case_record)

    socket
    |> assign(:case, case_record)
    |> assign(:content, content)
    |> assign(:conversation_context, conversation_context(case_record, content))
    |> assign(:owner_active_strikes, Moderation.active_strike_count(case_record.owner))
    |> assign(:events, Moderation.case_events(case_record))
    |> assign(
      :severance_by_reporter,
      Map.new(Moderation.case_severances(case_record), &{&1.reporter_id, &1})
    )
    |> assign(
      :reporter_stats,
      Map.new(case_record.reports, fn report ->
        {report.id, Map.fetch!(stats_by_reporter, report.reporter_id)}
      end)
    )
  end

  # For message cases: the reported message in its conversation (the last few
  # messages before it), so the admin can judge bullying in context. Takes the
  # already-loaded content (assign_case fetched it) rather than re-querying.
  defp conversation_context(%Case{content_type: "message"}, nil), do: []

  defp conversation_context(%Case{content_type: "message"}, message),
    do: Chat.moderation_context(message)

  defp conversation_context(_case_record, _content), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("Moderation case")}
      crumbs={[
        {gettext("Admin"), ~p"/admin"},
        {gettext("Moderation"), ~p"/admin/moderation"},
        gettext("Case")
      ]}
    />

    <div class="card-list">
      <%!-- Who this is about, and where the case stands. --%>
      <section class="card">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="flex items-center gap-4">
            <.avatar user={@case.owner} size="md" shape="square" />
            <div>
              <p class="text-lg font-semibold text-slate-900 dark:text-slate-100">
                {full_name(@case.owner)}
              </p>
              <p class="text-sm">
                <a href={~p"/#{@case.owner}"} class="font-semibold text-brand-600 hover:text-brand-700">
                  @{@case.owner.username}
                </a>
                <span class={[
                  "ml-2",
                  if(@owner_active_strikes > 0,
                    do: "font-semibold text-red-600 dark:text-red-400",
                    else: "text-slate-600 dark:text-slate-400"
                  )
                ]}>
                  {ngettext("%{count} active strike", "%{count} active strikes", @owner_active_strikes)}
                </span>
              </p>
            </div>
          </div>

          <div class="text-sm sm:text-right">
            <p>
              <span class="font-semibold">{content_type_label(@case.content_type)}</span>
              <span class={[
                "ml-1 rounded-full px-2 py-0.5 text-xs font-bold",
                status_tone(@case)
              ]}>
                {status_badge(@case)}
              </span>
            </p>
            <p class="mt-1 text-slate-600 dark:text-slate-400">
              {gettext("Reported on %{date}",
                date: Calendar.strftime(@case.inserted_at, "%Y-%m-%d %H:%M")
              )}
            </p>
            <p :if={@case.owner_deadline_at} class="text-slate-600 dark:text-slate-400">
              {gettext("Owner deadline: %{date}",
                date: Calendar.strftime(@case.owner_deadline_at, "%Y-%m-%d %H:%M")
              )}
            </p>
            <p :if={@case.escalated_at} class="text-slate-600 dark:text-slate-400">
              {gettext("Escalated on %{date}",
                date: Calendar.strftime(@case.escalated_at, "%Y-%m-%d %H:%M")
              )}
            </p>
          </div>
        </div>
      </section>

      <%!-- The evidence: what was reported, as it looked at report time. --%>
      <section class="card">
        <.section_title>{gettext("Evidence")}</.section_title>

        <%= if @case.content_type == "user" do %>
          <p class="mt-3 text-sm text-slate-600 dark:text-slate-400">
            {gettext(
              "The whole profile was reported. Judge the profile itself - the snapshot below only preserves the name at report time."
            )}
          </p>
          <p class="mt-2">
            <a href={~p"/#{@case.owner}"} class="text-sm font-semibold text-brand-600 hover:text-brand-700">
              {gettext("Open the profile")} ›
            </a>
          </p>
        <% end %>

        <p :if={@case.content_type == "job_posting" && @content} class="mt-3">
          <a
            href={~p"/jobs/#{@content.slug}"}
            class="text-sm font-semibold text-brand-600 hover:text-brand-700"
          >
            {gettext("Open the job posting")} ›
          </a>
        </p>

        <blockquote class="mt-3 rounded-lg bg-slate-50 p-3 text-sm ring-1 ring-slate-200 dark:bg-slate-800 dark:ring-slate-700">
          {@case.content_snapshot || gettext("(no text)")}
        </blockquote>

        <div :if={@case.evidence_screenshot}>
          <p class="mt-4 text-sm font-semibold">{gettext("Screenshot at report time")}</p>
          <div class="mt-1 max-h-[480px] overflow-auto rounded-lg ring-1 ring-slate-200 dark:ring-slate-700">
            <a href={~p"/admin/moderation/#{@case.id}/evidence"} target="_blank">
              <img
                src={~p"/admin/moderation/#{@case.id}/evidence"}
                alt={gettext("Evidence screenshot captured when the report was filed")}
                class="w-full"
              />
            </a>
          </div>
          <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
            {gettext("Scroll inside the frame, or click to open the full image.")}
          </p>
        </div>

        <div :if={@case.content_type == "post" && @content && @content.body != @case.content_snapshot}>
          <p class="mt-4 text-sm font-semibold">{gettext("Current version (edited since the report)")}</p>
          <blockquote class="mt-1 rounded-lg bg-slate-50 p-3 text-sm ring-1 ring-slate-200 dark:bg-slate-800 dark:ring-slate-700">
            {@content.body}
          </blockquote>
        </div>

        <div :if={@conversation_context != []}>
          <p class="mt-4 text-sm font-semibold">
            {gettext("Conversation context (the reported message last)")}
          </p>
          <div class="mt-1 space-y-1">
            <p
              :for={message <- @conversation_context}
              class={[
                "rounded-lg p-2 text-sm ring-1",
                if(message.id == @case.content_id,
                  do: "bg-amber-50 ring-amber-200 dark:bg-amber-900/30 dark:ring-amber-900",
                  else: "bg-slate-50 ring-slate-200 dark:bg-slate-800 dark:ring-slate-700"
                )
              ]}
            >
              <span class="font-semibold">
                @{(message.sender && message.sender.username) || gettext("(deleted account)")}:
              </span>
              {message.body}
            </p>
          </div>
        </div>
      </section>

      <%!-- Every report on this case, with the reporter's track record. --%>
      <section class="card">
        <.section_title>{gettext("Reports")}</.section_title>

        <ul class="mt-3 space-y-3">
          <li :for={report <- @case.reports} class="text-sm">
            <p>
              <span class="inline-flex items-center rounded-lg bg-brand-50 px-2 py-0.5 text-xs font-medium text-brand-700 dark:bg-brand-900/40 dark:text-brand-100">
                {category_label(report.category)}
              </span>
              <a href={~p"/#{report.reporter}"} class="ml-1 font-semibold text-brand-600 hover:text-brand-700">
                @{report.reporter.username}
              </a>
              <% stats = @reporter_stats[report.id] %>
              <span class="text-slate-600 dark:text-slate-400">
                · {ngettext("%{count} report so far", "%{count} reports so far", stats.total)}, {gettext(
                  "%{rejected} rejected, %{abusive} abusive",
                  rejected: stats.rejected,
                  abusive: stats.abusive
                )}
              </span>
            </p>
            <p :if={report.note not in [nil, ""]} class="mt-1 text-slate-600 dark:text-slate-400">
              „{report.note}"
            </p>
            <% severance = @severance_by_reporter[report.reporter_id] %>
            <p :if={severance} class="mt-1 text-xs text-slate-600 dark:text-slate-400">
              <%= if severance.restored_at do %>
                {gettext("The protective separation from the owner was lifted on %{date}.",
                  date: Calendar.strftime(severance.restored_at, "%Y-%m-%d")
                )}
              <% else %>
                {gettext(
                  "Reporter and owner are separated since this report (connection, follows, messages)."
                )}
              <% end %>
            </p>
          </li>
        </ul>
      </section>

      <%!-- The audit log: everything that happened to this case, oldest first. --%>
      <section class="card">
        <.section_title>{gettext("History")}</.section_title>

        <p :if={@events == []} class="card__empty">
          {gettext("No history recorded - this case predates the audit log.")}
        </p>

        <ol id="case-timeline" class="mt-3 space-y-2 text-sm">
          <li :for={event <- @events} class="flex gap-3">
            <.local_time
              at={event.inserted_at}
              id={"event-time-#{event.id}"}
              class="shrink-0 pt-0.5 text-xs tabular-nums text-slate-600 dark:text-slate-400"
            />
            <span>
              {event_label(event.action)}
              <a :if={event.actor} href={~p"/#{event.actor}"} class="text-slate-600 dark:text-slate-400 hover:text-brand-700">
                · @{event.actor.username}
              </a>
              <% detail = event_detail(event.action, event.detail) %>
              <span :if={detail not in [nil, ""]} class="text-slate-600 dark:text-slate-400">· {detail}</span>
            </span>
          </li>
        </ol>
      </section>

      <%!-- The ruling. Upholding strikes the owner (red); rejecting clears them. --%>
      <section :if={@case.status in ["pending_owner", "flagged", "escalated"]} class="card">
        <.section_title>{gettext("Decision")}</.section_title>

        <div class="mt-3 grid gap-4 md:grid-cols-2">
          <div class="rounded-lg border border-red-200 p-4 dark:border-red-900">
            <p class="text-sm text-slate-600 dark:text-slate-400">
              {gettext(
                "The report is justified. The content stays hidden and the owner gets a strike (warn, suspend, deactivate)."
              )}
            </p>
            <button type="button" class="button button--danger mt-3" id="uphold-case" phx-click="uphold">
              {gettext("Uphold the report")}
            </button>
          </div>

          <.form
            for={%{}}
            id="reject-form"
            phx-submit="reject"
            class="rounded-lg border border-slate-200 p-4 dark:border-slate-700"
          >
            <p class="text-sm text-slate-600 dark:text-slate-400">
              {gettext(
                "The report is unfounded. The content becomes visible again, any protective separation is lifted, and the rejection counts against each reporter's trust."
              )}
            </p>
            <label :for={report <- @case.reports} class="mt-2 flex items-start gap-2 text-sm">
              <input type="checkbox" name="abusive_report_ids[]" value={report.id} class="mt-0.5" />
              <span>
                {gettext("The report by @%{slug} was a deliberate weapon (strikes the reporter)",
                  slug: report.reporter.username
                )}
              </span>
            </label>
            <button type="submit" class="button button--secondary mt-3" id="reject-case">
              {gettext("Reject the report")}
            </button>
          </.form>
        </div>

        <%!-- The decisive spam/abuse path: remove the account outright, no
        warn-first ladder. Acts on the case owner, so it is offered on every open
        case (a spammy post has a spammer behind it), not just profile cases. --%>
        <div class="mt-4 rounded-lg border border-red-300 bg-red-50/40 p-4 dark:border-red-900 dark:bg-red-950/20">
          <p class="text-sm font-semibold text-red-700 dark:text-red-300">
            {gettext("Clear-cut spam or abuse?")}
          </p>
          <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
            {gettext(
              "Remove the account outright, skipping the warning ladder. Deactivating marks it as spam and is reversible from the member browser; deleting is permanent."
            )}
          </p>
          <div class="mt-3 flex flex-wrap gap-3">
            <button
              type="button"
              class="button button--danger"
              id="remove-deactivate"
              phx-click="remove"
              phx-value-action="deactivate"
              data-confirm={
                gettext("Deactivate @%{slug} and mark the account as spam?", slug: @case.owner.username)
              }
            >
              {gettext("Deactivate account")}
            </button>
            <button
              type="button"
              class="button button--danger"
              id="remove-delete"
              phx-click="remove"
              phx-value-action="delete"
              data-confirm={
                gettext(
                  "Permanently DELETE @%{slug} and everything they posted? This cannot be undone.",
                  slug: @case.owner.username
                )
              }
            >
              {gettext("Delete account")}
            </button>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
