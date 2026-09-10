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
  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.Moderation
  alias Vutuv.Moderation.Report
  alias Vutuv.Posts
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.ErrorHelpers

  def new(conn, %{"type" => type, "id" => id} = params) do
    case Moderation.fetch_content(type, id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      content ->
        reporter = conn.assigns[:current_user]

        if Moderation.can_report?(reporter, content) do
          render_report_form(conn, reporter, content,
            content_type: type,
            content_id: id,
            return_to: ControllerHelpers.safe_return_to(params["return_to"])
          )
        else
          # Mirror create's authorization: never preview content the reporter
          # has no right to see (a private DM, a restricted post).
          ControllerHelpers.render_error(conn, 404)
        end
    end
  end

  def new(conn, _params), do: ControllerHelpers.render_error(conn, 404)

  defp render_report_form(conn, reporter, content, assigns) do
    # A reporter tied to the owner must understand BEFORE sending that
    # the report separates the two of them (and thereby de-facto reveals
    # who reported). Strangers keep the plain anonymity promise.
    severs = Moderation.would_sever_relationship?(reporter, content)

    defaults = [
      page_title: gettext("Report content"),
      # Off the row, not off the wire string: a press picture offers `spam` and
      # a profile picture does not, and this is the same list the changeset
      # validates against (issue #2089).
      categories: Moderation.report_categories(content),
      preview: preview(content),
      # A picture is the one reportable thing whose preview cannot be a
      # sentence: a rights holder has to see WHICH picture this is before they
      # send a legal notice about it.
      preview_image: preview_image(content),
      severed_owner: if(severs, do: Moderation.content_owner(content)),
      # The form is sticky through the report itself, so a rejected submission
      # comes back the way the reporter left it.
      report: %Report{},
      errors: []
    ]

    render(conn, "new.html", Keyword.merge(defaults, assigns))
  end

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

          # Back to the form rather than a redirect + flash: a copyright notice
          # carries a written explanation the reporter must not lose to a
          # missing checkbox.
          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> render_report_form(reporter, content,
              content_type: type,
              content_id: id,
              return_to: return_to,
              report: Ecto.Changeset.apply_changes(changeset),
              errors: ErrorHelpers.changeset_messages(changeset)
            )
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
    base = report_received_sentence(case_record)

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

  # A report that visibly changes nothing has to say so, or it feels inert. That
  # is a whole profile, and since issue #2030 also a picture reported under the
  # house rules: only a copyright notice takes a picture offline on the spot, so
  # a "flagged" picture case is one where nothing moved.
  defp report_received_sentence(%{content_type: "user"}) do
    gettext(
      "Thank you for your report. Our moderators have been notified and will review this account."
    )
  end

  defp report_received_sentence(%{content_type: "image", status: "flagged"}) do
    gettext(
      "Thank you for your report. Our moderators have been notified and will review this picture."
    )
  end

  defp report_received_sentence(_case_record) do
    gettext("Thank you for your report. We take it from here.")
  end

  # A short quote of what is being reported, so the reporter can double-check
  # they hit the right thing.
  defp preview(%Posts.Post{body: body}), do: clip(body)
  defp preview(%Chat.Message{body: body}), do: clip(body)

  defp preview(%User{} = user),
    do: "@#{user.username} - #{VutuvWeb.UserHelpers.full_name(user)}"

  defp preview(%Vutuv.Organizations.Organization{} = organization),
    do: "#{organization.name} - #{organization.city}"

  defp preview(%Vutuv.Jobs.JobPosting{} = posting), do: clip(posting.title)

  defp preview(%Image{kind: "cover"}), do: gettext("Cover photo")

  # A press picture is one of many, so the shelf alone would not tell the
  # reporter which one they are about to file a notice on. The variant label
  # (`alt`) rides along where the owner wrote one; the picture itself is above
  # this line anyway, which is what `preview_image/1` is for.
  defp preview(%Image{kind: "press_kit"} = image) do
    [press_kit_label(image), image.alt]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" - ")
    |> clip()
  end

  defp preview(%Image{}), do: gettext("Profile picture")

  defp press_kit_label(%Image{} = image) do
    if Image.logo?(image), do: gettext("Logo variant"), else: gettext("Press photo")
  end

  # The picture itself, for the report form — through `Vutuv.Images`, which
  # owns kind → uploader, so a picture already held by another case (or still
  # in the AI gate) shows the silhouette here too rather than a URL nothing
  # answers.
  defp preview_image(%Image{} = image), do: Images.preview_url(image)
  defp preview_image(_content), do: nil

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
