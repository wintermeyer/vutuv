defmodule VutuvWeb.Admin.ModerationController do
  @moduledoc """
  The classic routes behind the moderation flow. The queue and the case page are
  LiveViews (`ModerationLive`, `ModerationCaseLive`), where the one-click rulings
  act reload-free; this controller keeps what cannot be a LiveView or is the
  no-JS fallback: the read-only reporter dashboard, the private evidence-
  screenshot stream, and the uphold/reject POSTs. Uphold strikes the owner and
  keeps the content frozen; reject unfreezes it and optionally marks reports
  abusive (striking the reporter).
  """

  use VutuvWeb, :controller

  alias Vutuv.Moderation
  alias Vutuv.Moderation.EvidenceScreenshot
  alias VutuvWeb.ControllerHelpers

  # Streams the private evidence screenshot (captured at report time). The
  # moderation_evidence/ tree has no static mount; this authorizing route
  # (admin pipeline) is the only way to it.
  def evidence(conn, %{"id" => id}) do
    with case_record when not is_nil(case_record) <- Moderation.get_case_with_details(id),
         filename when is_binary(filename) <- case_record.evidence_screenshot,
         path = EvidenceScreenshot.path(filename),
         true <- File.exists?(path) do
      conn
      |> put_resp_content_type("image/webp")
      |> send_file(200, path)
    else
      _ -> ControllerHelpers.render_error(conn, 404)
    end
  end

  def uphold(conn, %{"id" => id}) do
    with_case(conn, id, fn case_record ->
      case Moderation.uphold_case(case_record, conn.assigns[:current_user]) do
        {:ok, _} ->
          conn
          |> put_flash(:info, gettext("Report upheld; the owner got a strike."))
          |> redirect(to: ~p"/admin/moderation")

        {:error, :not_open} ->
          already_resolved(conn)
      end
    end)
  end

  def reject(conn, %{"id" => id} = params) do
    abusive_ids = params |> Map.get("abusive_report_ids", []) |> List.wrap()

    with_case(conn, id, fn case_record ->
      case Moderation.reject_case(case_record, conn.assigns[:current_user], abusive_ids) do
        {:ok, _} ->
          conn
          |> put_flash(:info, gettext("Report rejected; the content is visible again."))
          |> redirect(to: ~p"/admin/moderation")

        {:error, :not_open} ->
          already_resolved(conn)
      end
    end)
  end

  def reporters(conn, _params) do
    render(conn, "reporters.html",
      page_title: gettext("Reporter track records"),
      stats: Moderation.list_reporter_stats()
    )
  end

  # Load the case-with-details or render the shared 404 — the load-or-404 guard
  # the uphold/reject actions share.
  defp with_case(conn, id, fun) do
    case Moderation.get_case_with_details(id) do
      nil -> ControllerHelpers.render_error(conn, 404)
      case_record -> fun.(case_record)
    end
  end

  # The shared "already settled" outcome of a ruling on a closed case.
  defp already_resolved(conn) do
    conn
    |> put_flash(:error, gettext("This case has already been resolved."))
    |> redirect(to: ~p"/admin/moderation")
  end
end
