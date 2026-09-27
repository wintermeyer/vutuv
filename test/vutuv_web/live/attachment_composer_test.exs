defmodule VutuvWeb.AttachmentComposerTest do
  @moduledoc """
  The composer's file handling (issue #2104): the picker, the real upload path,
  the chip the accepted file leaves, the sentence a refusal leaves, and the
  remaining budget the member reads before the next file flows.

  `async: false` because it flips `:attachments` and `:uploads_dir_prefix`,
  both global — `Vutuv.Attachments`, the composer and the sweeper all read the
  first, and every uploader reads the second.
  """

  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments

  setup %{conn: conn} do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_attachment_ui_#{System.unique_integer([:positive])}")

    files = Path.join(tmp, "files")
    File.mkdir_p!(files)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    # Uploads are for admins until an installation opens them
    # (ATTACHMENT_UPLOADERS), so the composer is opened as one.
    {conn, user} = create_and_login_admin(conn)
    %{conn: conn, user: user, files: files}
  end

  defp open_composer(conn) do
    {:ok, live, _html} = live(conn, ~p"/feed")
    live |> element("#open-composer") |> render_click()
    live
  end

  defp upload!(live, path, type \\ "application/pdf") do
    content = File.read!(path)
    name = "#{System.unique_integer([:positive])}-#{Path.basename(path)}"

    input =
      file_input(live, "#composer-form", :attachments, [
        %{name: name, content: content, type: type, size: byte_size(content)}
      ])

    render_upload(input, name)
  end

  test "a member who is not an admin is offered no files where uploads are for admins" do
    Fixtures.put_config(uploaders: :admins)

    {conn, _member} =
      build_conn() |> Plug.Test.init_test_session(%{}) |> create_and_login_user()

    live = open_composer(conn)

    refute has_element?(live, "#composer-add-files")
    refute has_element?(live, "input[type=file][name=attachments]")
  end

  test "the picker is there and an accepted file leaves a chip with its size", %{
    conn: conn,
    user: user,
    files: files
  } do
    live = open_composer(conn)
    assert has_element?(live, "#composer-add-files")

    html = upload!(live, Fixtures.plain_pdf(files))

    assert html =~ "plain.pdf"
    assert has_element?(live, "#composer-attachments")
    assert has_element?(live, "button[phx-click=remove-attachment]")

    # The size goes through the shared formatter rather than being interpolated
    # as a bare integer.
    attachment = newest_attachment(user)
    assert html =~ VutuvWeb.UI.file_size(attachment.size_bytes)

    # The remove button's label names the file. Asserted because the English
    # catalogue shipped this msgid with `%{pattern}` in place of `%{name}` —
    # a fuzzy fill nothing flags, which renders the placeholder itself and
    # logs a missing-bindings error on every render.
    assert has_element?(live, ~s|button[aria-label="Remove #{attachment.file_name}"]|)
  end

  test "an admin, who has no allowance, is not told so", %{conn: conn, files: files} do
    live = open_composer(conn)
    upload!(live, Fixtures.plain_pdf(files))

    refute render(live) =~ "Your uploads are not limited."
  end

  test "a plain member reads a formatted allowance once a file is attached", %{
    conn: _conn,
    files: files
  } do
    Fixtures.put_config(uploaders: :members, daily_budget: 100_000_000)

    {conn, _member} =
      build_conn() |> Plug.Test.init_test_session(%{}) |> create_and_login_user()

    live = open_composer(conn)
    refute render(live) =~ "(100 %)"

    html = upload!(live, Fixtures.plain_pdf(files))

    assert html =~ "100 MB"
  end

  test "a refused PDF says which of the four things it is", %{conn: conn, files: files} do
    live = open_composer(conn)

    html = upload!(live, Fixtures.javascript_pdf(files))

    assert html =~ "contains a program"
    refute has_element?(live, "#composer-attachments")
  end

  test "the remove button takes the file and its bytes", %{conn: conn, user: user, files: files} do
    live = open_composer(conn)
    upload!(live, Fixtures.plain_pdf(files))

    attachment = newest_attachment(user)

    live |> element(~s|button[phx-value-id="#{attachment.id}"]|) |> render_click()

    refute has_element?(live, "#composer-attachments")
    assert Attachments.pending_for(user, [attachment.id]) == []
  end

  test "discarding the draft takes the files along, and undo brings them back", %{
    conn: conn,
    files: files
  } do
    live = open_composer(conn)
    upload!(live, Fixtures.plain_pdf(files))
    assert has_element?(live, "#composer-attachments")

    live |> element("#composer-discard") |> render_click()
    refute has_element?(live, "#composer-attachments")

    live |> element("[data-undo-discard]") |> render_click()
    assert has_element?(live, "#composer-attachments")
  end

  test "posting a post that waits on its file folds the composer away", %{
    conn: conn,
    files: files
  } do
    live = open_composer(conn)

    # An earlier discard's undo must not outlive the post written after it.
    live |> form("#composer-form", %{"post" => %{"body" => "Alt"}}) |> render_change()
    live |> element("#composer-discard") |> render_click()
    assert has_element?(live, "[data-draft-discarded]")
    live |> element("#open-composer") |> render_click()

    upload!(live, Fixtures.plain_pdf(files))

    live
    |> form("#composer-form", %{"post" => %{"body" => "Mit Datei"}})
    |> render_submit()

    # The file is not rendered yet, so the post waits — and the composer
    # behaves as after any post: empty, folded, no stale undo.
    assert has_element?(live, "#composer-panel.hidden")
    refute has_element?(live, "[data-draft-discarded]")
    refute has_element?(live, "#composer-attachments")
  end

  test "the German composer names the drop area in German", %{conn: conn} do
    html =
      conn
      |> Phoenix.ConnTest.recycle()
      |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
      |> open_composer()
      |> render()

    # Each one by name: `gettext.extract --merge` fuzzy-filled "Choose a file"
    # with "Sprache auswählen" and "Add more" with "Notiz hinzufügen".
    assert html =~ "Dateien hierher ziehen"
    assert html =~ "Fotos, Videos oder Dateien"
    assert html =~ "Zum Anhängen loslassen"
    assert html =~ "Datei auswählen"
    assert html =~ "Fotos, Videos, PDF, Text"

    # Under an empty composer the allowance was a sentence about nothing.
    refute html =~ "Ihre Uploads sind nicht begrenzt."
  end

  defp newest_attachment(user) do
    import Ecto.Query

    Vutuv.Repo.one!(
      from(a in Vutuv.Attachments.Attachment,
        where: a.user_id == ^user.id,
        order_by: [desc: a.id],
        limit: 1
      )
    )
  end
end
