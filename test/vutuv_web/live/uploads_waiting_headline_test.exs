defmodule VutuvWeb.UploadsWaitingHeadlineTest do
  @moduledoc """
  The headline over a post that waits for its files, on `/system/uploads`.

  It has to say what is happening, not only that something will be "ready":
  "Ihr Beitrag erscheint, sobald seine Dateien fertig sind" left a member
  guessing who was finishing what. Asserted in German by name, because
  `mix gettext.extract --merge` fuzzy-fills a new msgid and nothing fails.

  `async: false`: it flips `:uploads_dir_prefix`, which is global state.
  """

  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Posts.Pending

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_waiting_ui_#{System.unique_integer([:positive])}")
    files = Path.join(tmp, "files")
    File.mkdir_p!(files)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {conn, user} = create_and_login_admin(conn)

    {:ok, attachment} =
      Attachments.create_pending(user, Fixtures.text_file(files), "wartebericht.txt")

    {:ok, _pending} =
      Pending.create(user, "post", %{}, %{body: "Waiting"}, attachments: [attachment])

    %{conn: conn}
  end

  test "the headline says preview images are being created and checked", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/system/uploads")

    assert html =~ ~s(data-pending-status="working")
    assert html =~ "Preview images are being created and checked."
    refute html =~ "as soon as its files are ready"
  end

  test "and says it in German", %{conn: conn} do
    {:ok, _live, html} =
      conn
      |> Phoenix.ConnTest.recycle()
      |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
      |> live(~p"/system/uploads")

    assert html =~ "Vorschaubilder werden erstellt und überprüft."
    refute html =~ "sobald seine Dateien fertig sind"
  end
end
