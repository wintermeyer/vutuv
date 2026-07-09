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
        reporter = conn.assigns[:current_user]

        # A reporter tied to the owner must understand BEFORE sending that
        # the report separates the two of them (and thereby de-facto reveals
        # who reported). Strangers keep the plain anonymity promise.
        severs = Moderation.would_sever_relationship?(reporter, content)

        render(conn, "new.html",
          page_title: gettext("Report content"),
          content_type: type,
          content_id: id,
          preview: preview(content),
          severed_owner: if(severs, do: Moderation.content_owner(content)),
          return_to: ControllerHelpers.safe_return_to(params["return_to"])
        )
    end
  end

  def new(conn, _params), do: ControllerHelpers.render_error(conn, 404)

  def create(conn, %{"report" => %{"type" => type, "id" => id} = report_params}) do
    reporter = conn.assigns[:current_user]
    return_to = ControllerHelpers.safe_return_to(report_params["return_to"]) || ~p"/"

    case Moderation.fetch_content(type, id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      content ->
        case Moderation.report_content(reporter, content, report_params) do
          {:ok, case_record} ->
            conn
            |> put_flash(:info, report_received_flash(case_record, reporter))
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

  # The reporter's confirmation. A whole-profile report (the spam case) says the
  # moderators have been notified and will review the account, so reporting no
  # longer feels inert. When the report also severed a standing relationship, the
  # reporter must understand why things just disappeared: paused both ways, undone
  # if the report turns out unfounded. (The same explanation lands in their
  # notifications feed, which outlives the flash.)
  defp report_received_flash(case_record, reporter) do
    base =
      if case_record.content_type == "user" do
        gettext(
          "Thank you for your report. Our moderators have been notified and will review this account."
        )
      else
        gettext("Thank you for your report. We take it from here.")
      end

    if Moderation.severed_for?(case_record.id, reporter.id) do
      base <>
        " " <>
        gettext(
          "To protect you, the connection between you and the reported member is paused - no contact in either direction, including messages. If our admins find the report unfounded, this is undone."
        )
    else
      base
    end
  end

  # A short quote of what is being reported, so the reporter can double-check
  # they hit the right thing.
  defp preview(%Posts.Post{body: body}), do: clip(body)
  defp preview(%Chat.Message{body: body}), do: clip(body)

  defp preview(%User{} = user),
    do: "@#{user.username} - #{VutuvWeb.UserHelpers.full_name(user)}"

  defp clip(nil), do: ""

  # Measure the cap in graphemes, consistent with the grapheme-based slice:
  # a `byte_size` guard let an umlaut/emoji-heavy body under 280 graphemes but
  # over 280 bytes skip the short-circuit, get sliced to its full length and
  # still gain a spurious trailing "…".
  defp clip(body) do
    if String.length(body) <= 280 do
      body
    else
      String.slice(body, 0, 280) <> "…"
    end
  end
end
