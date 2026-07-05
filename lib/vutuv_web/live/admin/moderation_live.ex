defmodule VutuvWeb.Admin.ModerationLive do
  @moduledoc """
  The admin moderation queue (`/admin/moderation`): the open cases the
  self-service flow could not settle, escalated ones first. A read-only list that
  links to the case page (`ModerationCaseLive`), where the ruling happens. The
  bounded backlog is loaded once on mount; a ruling navigates back here, which
  re-mounts with the settled case gone. Lives in the `:admin` live_session.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.Admin.ModerationHTML,
    only: [status_badge: 1, content_type_label: 1, category_label: 1]

  alias Vutuv.Moderation

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Moderation queue"))
     |> assign(:cases, Moderation.list_queue())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("Moderation queue")}
      crumbs={[{gettext("Admin"), ~p"/admin"}, gettext("Moderation")]}
    />

    <div class="card-list">
      <section class="card">
        <div class="flex items-center justify-between gap-4">
          <h1>{gettext("Open cases")} ({compact_count(length(@cases))})</h1>
          <a
            href={~p"/admin/moderation/reporters"}
            class="text-sm font-semibold text-brand-600 hover:text-brand-700"
          >
            {gettext("Reporter track records")} ›
          </a>
        </div>

        <p :if={@cases == []} class="card__empty">
          {gettext("The queue is empty - the self-service flow settled everything.")}
        </p>

        <div :if={@cases != []} class="card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("Status")}</th>
                <th>{gettext("Type")}</th>
                <th>{gettext("Reported as")}</th>
                <th>{gettext("Owner")}</th>
                <th>{gettext("Reports")}</th>
                <th>{gettext("Opened")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={case_record <- @cases} id={"case-row-#{case_record.id}"}>
                <td>
                  <span class={[
                    "rounded-full px-2 py-0.5 text-xs font-bold",
                    case_record.status == "escalated" && "bg-accent/10 text-accent",
                    case_record.status == "flagged" &&
                      "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-200"
                  ]}>
                    {status_badge(case_record)}
                  </span>
                </td>
                <td>{content_type_label(case_record.content_type)}</td>
                <td>
                  {case_record.reports
                  |> Enum.map(& &1.category)
                  |> Enum.uniq()
                  |> Enum.map_join(", ", &category_label/1)}
                </td>
                <td>
                  <a href={~p"/#{case_record.owner}"}>@{case_record.owner.username}</a>
                </td>
                <td>{compact_count(length(case_record.reports))}</td>
                <td><.local_time at={case_record.inserted_at} id={"case-time-#{case_record.id}"} /></td>
                <td class="text-right">
                  <a
                    href={~p"/admin/moderation/#{case_record.id}"}
                    class="text-sm font-semibold text-brand-600 hover:text-brand-700"
                  >
                    {gettext("Review")} ›
                  </a>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end
end
