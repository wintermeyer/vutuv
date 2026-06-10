defmodule VutuvWeb.ModerationCaseController do
  @moduledoc """
  The owner's side of a moderation case: see what was reported, then settle
  it without an admin — delete the content, edit it (posts unfreeze on edit),
  or dispute the report ("my content is fine"), which escalates to the admin
  queue. Admins may also open these pages read-only.
  """

  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.RequireLogin)

  alias Vutuv.Moderation
  alias Vutuv.Moderation.Case
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    user = conn.assigns[:current_user]

    render(conn, "index.html",
      page_title: gettext("Reported content"),
      cases: Moderation.open_cases_for_owner(user)
    )
  end

  def show(conn, %{"id" => id}) do
    with %Case{} = case_record <- Moderation.get_case_with_details(id),
         :ok <- authorize(conn, case_record) do
      render(conn, "show.html",
        page_title: gettext("Reported content"),
        case: case_record,
        content: Moderation.case_content(case_record)
      )
    else
      _ -> ControllerHelpers.render_error(conn, 404)
    end
  end

  def dispute(conn, %{"id" => id}) do
    with %Case{} = case_record <- Moderation.get_case_with_details(id),
         {:ok, _} <- Moderation.dispute_case(case_record, conn.assigns[:current_user]) do
      conn
      |> put_flash(
        :info,
        gettext("Understood. The content stays hidden until one of our admins has ruled.")
      )
      |> redirect(to: ~p"/moderation/cases/#{id}")
    else
      nil -> ControllerHelpers.render_error(conn, 404)
      {:error, :not_allowed} -> ControllerHelpers.render_error(conn, 404)
      {:error, :not_open} -> already_settled(conn, id)
    end
  end

  def delete_content(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Moderation.get_case_with_details(id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      case_record ->
        case Moderation.delete_reported_content(case_record, user) do
          :ok ->
            conn
            |> put_flash(
              :info,
              gettext("Deleted. The report is settled, no further steps needed.")
            )
            |> redirect(to: ~p"/moderation/cases/#{id}")

          {:error, :not_allowed} ->
            ControllerHelpers.render_error(conn, 404)

          {:error, _already_deleted_or_not_deletable} ->
            already_settled(conn, id)
        end
    end
  end

  defp already_settled(conn, case_id) do
    conn
    |> put_flash(:info, gettext("This case is already settled."))
    |> redirect(to: ~p"/moderation/cases/#{case_id}")
  end

  defp authorize(conn, %Case{} = case_record) do
    user = conn.assigns[:current_user]

    if case_record.owner_id == user.id or user.admin? == true do
      :ok
    else
      :error
    end
  end
end
