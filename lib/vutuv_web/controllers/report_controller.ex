defmodule VutuvWeb.ReportController do
  @moduledoc """
  The "Report" flow any member can reach from a post, a chat message or a
  profile. Two clicks: pick a category, optionally add a note, send. The
  heavy lifting (trust weighting, the freezer, owner notification) lives in
  `Vutuv.Moderation.report_content/3`.
  """

  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.RequireLogin)

  alias Vutuv.Accounts.User
  alias Vutuv.Chat
  alias Vutuv.Moderation
  alias Vutuv.Posts
  alias VutuvWeb.ControllerHelpers

  def new(conn, %{"type" => type, "id" => id} = params) do
    case Moderation.fetch_content(type, id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      content ->
        render(conn, "new.html",
          page_title: gettext("Report content"),
          content_type: type,
          content_id: id,
          preview: preview(content),
          return_to: safe_return_to(params["return_to"])
        )
    end
  end

  def new(conn, _params), do: ControllerHelpers.render_error(conn, 404)

  def create(conn, %{"report" => %{"type" => type, "id" => id} = report_params}) do
    reporter = conn.assigns[:current_user]
    return_to = safe_return_to(report_params["return_to"]) || ~p"/"

    case Moderation.fetch_content(type, id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      content ->
        case Moderation.report_content(reporter, content, report_params) do
          {:ok, _case} ->
            conn
            |> put_flash(
              :info,
              gettext("Thank you for your report. We take it from here.")
            )
            |> redirect(to: return_to)

          {:error, :already_reported} ->
            conn
            |> put_flash(
              :info,
              gettext("You already reported this. Our team is on it.")
            )
            |> redirect(to: return_to)

          {:error, :own_content} ->
            conn
            |> put_flash(:error, gettext("You cannot report your own content."))
            |> redirect(to: return_to)

          {:error, :not_allowed} ->
            ControllerHelpers.render_error(conn, 404)

          {:error, %Ecto.Changeset{}} ->
            conn
            |> put_flash(:error, gettext("Please pick a category."))
            |> redirect(to: ~p"/reports/new?type=#{type}&id=#{id}")
        end
    end
  end

  def create(conn, _params), do: ControllerHelpers.render_error(conn, 404)

  # A short quote of what is being reported, so the reporter can double-check
  # they hit the right thing.
  defp preview(%Posts.Post{body: body}), do: clip(body)
  defp preview(%Chat.Message{body: body}), do: clip(body)

  defp preview(%User{} = user),
    do: "@#{user.active_slug} - #{VutuvWeb.UserHelpers.full_name(user)}"

  defp clip(nil), do: ""
  defp clip(body) when byte_size(body) <= 280, do: body
  defp clip(body), do: String.slice(body, 0, 280) <> "…"

  # Only same-origin paths may be used as a post-report redirect target.
  defp safe_return_to("/" <> rest = path) when binary_part(rest, 0, 1) != "/", do: path
  defp safe_return_to(_), do: nil
end
