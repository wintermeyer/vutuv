defmodule VutuvWeb.ModerationCaseController do
  @moduledoc """
  The owner's side of a moderation case: see what was reported, then settle
  it without an admin — delete the content, edit it (posts unfreeze on edit),
  or dispute the report ("my content is fine"), which escalates to the admin
  queue. Admins may also open these pages read-only.
  """

  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.RequireLogin)

  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.Moderation
  alias Vutuv.Moderation.Case
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.ImageProxy

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
      content = Moderation.case_content(case_record)

      render(conn, "show.html",
        page_title: gettext("Reported content"),
        case: case_record,
        # What was claimed, in the reporters' words, and on what ground — the
        # same statement of reasons the owner's email carries (issue #2010).
        notice: Moderation.owner_notice(case_record),
        edit_offer: Moderation.owner_edit_offer(case_record, content),
        # What became of the content, for a settled case only — the same
        # measured answer its reporter is mailed (issue #2067), so the two
        # sides of one case cannot describe it differently.
        content_fate: settled_content_fate(case_record),
        content: content
      )
    else
      _ -> ControllerHelpers.render_error(conn, 404)
    end
  end

  # Only the two admin rulings: the owner's own delete and edit already say what
  # became of the content, because they are what became of it.
  defp settled_content_fate(%Case{status: status} = case_record)
       when status in ~w(upheld rejected),
       do: Moderation.reported_content_fate(case_record)

  defp settled_content_fate(%Case{}), do: nil

  @doc """
  The reported picture itself, for the two case pages — the owner's and the
  admin's — which is why it lives here rather than under `/admin`: one route,
  one authorization (`authorize/2`, owner or admin), one `<img src>` in both
  templates.

  A frozen picture is out of every tree nginx serves, so this is the **only**
  way to look at it, and an admin who cannot see it cannot rule on a copyright
  claim. It reads the hold first and falls back to the served tree for a
  picture that was reported but not frozen (an untrusted reporter only flags
  it). Anything else — another content type, a picture whose bytes are gone
  with an upheld case — is a 404.
  """
  def image(conn, %{"id" => id}) do
    with %Case{content_type: "image"} = case_record <- Moderation.get_case(id),
         :ok <- authorize(conn, case_record),
         %Image{} = image <- Moderation.case_content(case_record),
         path when is_binary(path) <- Images.bytes_path(image) do
      conn
      # Never cached, anywhere: these are the bytes a takedown is about, and a
      # copy in a proxy would outlive the freeze that moved them.
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_content_type(MIME.from_path(path), nil)
      |> send_file(200, path)
    else
      _ -> ControllerHelpers.render_error(conn, 404)
    end
  end

  @doc """
  The reported **file** itself, for the same two case pages and the same
  authorization (issue #2109). A freeze moves both copies out of every tree this
  app serves from, so this is the only way to open the document at all — and an
  admin who cannot read it cannot rule on a copyright claim about it.

  It reads the hold first and falls back to the served copy for a file that was
  reported but not frozen (a house-rule complaint moves nothing). Handed over as
  a download under the name the member uploaded it as, never rendered inline: it
  is a member's document of an arbitrary type, and this response is authorized
  for exactly two people.
  """
  def file(conn, %{"id" => id}) do
    with %Case{content_type: "attachment"} = case_record <- Moderation.get_case(id),
         :ok <- authorize(conn, case_record),
         %Attachment{} = attachment <- Moderation.case_content(case_record),
         path when is_binary(path) <- Attachments.bytes_path(attachment) do
      # Never cached, anywhere: these are the bytes a takedown is about, and a
      # copy in a proxy would outlive the freeze that moved them — which is the
      # same reason the message proxy hands a file over this way (#2110), so
      # both go through one function and the next header lands in both.
      ImageProxy.hand_over_private(conn, path, attachment.file_name, attachment.content_type)
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
