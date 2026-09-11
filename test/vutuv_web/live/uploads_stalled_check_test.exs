defmodule VutuvWeb.UploadsStalledCheckTest do
  @moduledoc """
  What the author's own queue at `/system/uploads` says when the AI check
  cannot run (issue #2149).

  The measurement that opened the issue was a sentence, not a state: on an
  installation whose scanner is down, the page said "Unsere KI prüft gerade
  1 Bild." at ten minutes, at a day and at thirty days. So the assertions here
  are the words, in both languages — the German most of all, because
  `mix gettext.extract --merge` fuzzy-fills a new msgid with some unrelated
  translation and nothing fails the build when it does.

  `async: false`: it flips `:uploads_dir_prefix`, which every uploader reads,
  and `Application.put_env/3` is global state the SQL sandbox does not roll
  back.
  """

  use VutuvWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Vutuv.AttachmentHelpers, only: [page!: 2, stalled_scan!: 2, stall_after_seconds: 0]
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Posts.Pending
  alias Vutuv.Repo

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_stalled_ui_#{System.unique_integer([:positive])}")
    files = Path.join(tmp, "files")
    File.mkdir_p!(files)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    # Files are an admin feature until an installation opens them up.
    {conn, user} = create_and_login_admin(conn)

    {:ok, attachment} =
      Attachments.create_pending(user, Fixtures.text_file(files), "wartebericht.txt")

    {:ok, _pending} =
      Pending.create(user, "post", %{}, %{body: "Waiting"}, attachments: [attachment])

    stalled_page!(attachment)

    %{conn: conn, user: user}
  end

  # A file whose render is done and whose one preview page has been waiting on
  # an unreachable scanner for longer than the ceiling.
  defp stalled_page!(%Attachment{} = attachment) do
    Repo.update_all(from(a in Attachment, where: a.id == ^attachment.id), set: [stage: "ready"])

    attachment
    |> page!("pending")
    |> stalled_scan!(stall_after_seconds() + 60)
  end

  test "the page says the check cannot run instead of that it is running", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/system/uploads")

    assert html =~ ~s(data-pending-status="stalled")
    assert html =~ "This post is waiting for a check that cannot run"
    assert html =~ "Our AI check cannot be reached at the moment"
    assert html =~ ~s(data-file-state="stalled")
    assert html =~ "waiting for the check"

    refute html =~ "being prepared",
           "the file row still says something is preparing it while the scanner is unreachable"

    refute html =~ "Our AI is checking",
           "the queue page still claims a check is in progress while the scanner is unreachable"
  end

  test "and says it in German", %{conn: conn} do
    {:ok, _live, html} =
      conn
      |> Phoenix.ConnTest.recycle()
      |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
      |> live(~p"/system/uploads")

    assert html =~ "Dieser Beitrag wartet auf eine Prüfung, die nicht läuft"
    assert html =~ "Unsere KI-Prüfung ist zurzeit nicht erreichbar"

    # The one the browser caught: a msgid added after the last extract renders
    # in English on a German page, and `gettext.extract --merge` then filled it
    # with "Wartet auf den Besitzer" — waiting for somebody else entirely.
    assert html =~ "wartet auf die Prüfung"

    refute html =~ "Unsere KI prüft gerade"
    refute html =~ "waiting for the check"
  end
end
