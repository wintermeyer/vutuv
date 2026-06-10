defmodule VutuvWeb.Admin.ModerationController do
  @moduledoc """
  The admin moderation queue. Admins only see what the self-service flow
  could not settle: disputes, ignored 72h deadlines, re-reports and profile
  cases. Two one-click rulings per case: uphold (strike the owner, content
  stays frozen) or reject (unfreeze; optionally mark reports as abusive,
  which strikes the reporter).
  """

  use VutuvWeb, :controller

  alias Vutuv.{Chat, Moderation}
  alias Vutuv.Moderation.Case
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    render(conn, "index.html",
      page_title: gettext("Moderation queue"),
      cases: Moderation.list_queue()
    )
  end

  def show(conn, %{"id" => id}) do
    case Moderation.get_case_with_details(id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      case_record ->
        stats_by_reporter =
          Moderation.reporter_stats_map(Enum.map(case_record.reports, & &1.reporter_id))

        render(conn, "show.html",
          page_title: gettext("Moderation case"),
          case: case_record,
          content: Moderation.case_content(case_record),
          conversation_context: conversation_context(case_record),
          owner_active_strikes: Moderation.active_strike_count(case_record.owner),
          reporter_stats:
            Map.new(case_record.reports, fn report ->
              {report.id, Map.fetch!(stats_by_reporter, report.reporter_id)}
            end)
        )
    end
  end

  def uphold(conn, %{"id" => id}) do
    case Moderation.get_case_with_details(id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      case_record ->
        {:ok, _} = Moderation.uphold_case(case_record, conn.assigns[:current_user])

        conn
        |> put_flash(:info, gettext("Report upheld; the owner got a strike."))
        |> redirect(to: ~p"/admin/moderation")
    end
  end

  def reject(conn, %{"id" => id} = params) do
    abusive_ids = params |> Map.get("abusive_report_ids", []) |> List.wrap()

    case Moderation.get_case_with_details(id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      case_record ->
        {:ok, _} =
          Moderation.reject_case(case_record, conn.assigns[:current_user], abusive_ids)

        conn
        |> put_flash(:info, gettext("Report rejected; the content is visible again."))
        |> redirect(to: ~p"/admin/moderation")
    end
  end

  def reporters(conn, _params) do
    render(conn, "reporters.html",
      page_title: gettext("Reporter track records"),
      stats: Moderation.list_reporter_stats()
    )
  end

  # For message cases: the reported message in its conversation (the last few
  # messages before it), so the admin can judge bullying in context.
  defp conversation_context(%Case{content_type: "message"} = case_record) do
    case Moderation.case_content(case_record) do
      nil -> []
      message -> Chat.moderation_context(message)
    end
  end

  defp conversation_context(_case_record), do: []
end
