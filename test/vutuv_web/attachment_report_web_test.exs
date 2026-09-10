defmodule VutuvWeb.AttachmentReportWebTest do
  @moduledoc """
  The two web surfaces a reported file reaches (issue #2109): the member's
  report form, and the authorized download both case pages link the file
  through.

  The form is submitted with `submit_with_csrf/3` rather than a bare `post/3`,
  because `Phoenix.ConnTest` sets `plug_skip_csrf_protection` on every conn —
  which once hid a login 403 in production (issue #759).

  Not async: it points the global `:uploads_dir_prefix` at a tmp dir and opens
  `ATTACHMENT_UPLOADERS` to members, both of which every process reads.
  """

  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.AttachmentStore
  alias Vutuv.Moderation
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  @copyright %{
    "category" => "copyright",
    "note" => "Das Papier ist meins, das Original steht auf example.com.",
    "good_faith?" => "true"
  }

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_report_web_#{System.unique_integer([:positive])}")
    src = Path.join(tmp, "src")
    File.mkdir_p!(src)
    put_config(:uploads_dir_prefix, tmp)
    # The audience the milestone flips to once a post can hand a file out
    # (#2108). Reporting has to work for a member's file, not only an admin's.
    Fixtures.put_config(uploaders: :members)
    on_exit(fn -> File.rm_rf(tmp) end)

    # All three logins here, in one order: each drives the real PIN flow and
    # reads the newest mail out of this process's mailbox, so interleaving them
    # with a test's own logins hands one of them somebody else's PIN.
    {author_conn, author} = create_and_login_user(conn)
    {reporter_conn, reporter} = create_and_login_user(conn)
    {admin_conn, _admin} = create_and_login_admin(conn)

    post = insert(:post, user: author)

    {:ok, attachment} =
      Attachments.create_pending(author, Fixtures.plain_pdf(src), "Papier Müller.pdf")

    Repo.update_all(from(a in Attachment, where: a.id == ^attachment.id),
      set: [post_id: post.id]
    )

    %{
      author_conn: author_conn,
      reporter_conn: reporter_conn,
      admin_conn: admin_conn,
      author: author,
      reporter: reporter,
      post: post,
      attachment: Repo.get!(Attachment, attachment.id)
    }
  end

  defp report!(reporter, attachment, attrs \\ @copyright) do
    {:ok, case_record} = Moderation.report_content(reporter, attachment, attrs)
    case_record
  end

  # `recycle/1` first: the login already sent a response on this conn, and a
  # header cannot be put on a sent one.
  defp german(conn),
    do: conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

  describe "the member report form" do
    test "names the file and says what a report of one does", %{
      reporter_conn: conn,
      attachment: attachment
    } do
      response =
        conn
        |> get(~p"/reports/new?#{[type: "attachment", id: attachment.id]}")
        |> html_response(200)

      assert response =~ "Papier Müller.pdf"
      assert response =~ "with the file left where it is"
    end

    # By name, and in German: `mix gettext.extract --merge` fuzzy-filled every
    # one of this change's new msgids with the **picture** sentence beside it,
    # and nothing about a fuzzy entry fails a build.
    test "says in German what a report of a file does", %{
      reporter_conn: conn,
      attachment: attachment
    } do
      response =
        conn
        |> german()
        |> get(~p"/reports/new?#{[type: "attachment", id: attachment.id]}")
        |> html_response(200)

      assert response =~ "die Datei bleibt am Beitrag"
      refute response =~ "das Bild bleibt sichtbar"
    end

    test "files a copyright notice through the form", %{
      reporter_conn: conn,
      author: author,
      attachment: attachment
    } do
      conn = get(conn, ~p"/reports/new?#{[type: "attachment", id: attachment.id]}")

      conn =
        submit_with_csrf(conn, ~p"/reports", %{
          "report" => Map.merge(@copyright, %{"type" => "attachment", "id" => attachment.id})
        })

      assert redirected_to(conn)

      case_record = Moderation.open_case_for(Repo.get!(Attachment, attachment.id))
      assert case_record.content_type == "attachment"
      assert case_record.owner_id == author.id
      assert case_record.status == "pending_owner"
      assert Repo.get!(Attachment, attachment.id).frozen_at
    end

    test "a member who cannot see the post cannot open the form", %{
      reporter_conn: conn,
      post: post,
      attachment: attachment
    } do
      Repo.update_all(from(p in Post, where: p.id == ^post.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      conn = get(conn, ~p"/reports/new?#{[type: "attachment", id: attachment.id]}")
      assert html_response(conn, 404)
    end
  end

  describe "the reported file's authorized download" do
    test "the owner gets the bytes as a named download", %{
      author_conn: conn,
      reporter: reporter,
      attachment: attachment
    } do
      case_record = report!(reporter, attachment)

      response = get(conn, ~p"/moderation/cases/#{case_record.id}/file")

      assert response.status == 200
      assert response.resp_body != ""

      # The RFC 5987 pair, not a bare `filename=`: the ASCII fallback for an old
      # client and the exact UTF-8 name for everybody else, so an umlaut in a
      # member's own file name survives their own download.
      assert [disposition] = Plug.Conn.get_resp_header(response, "content-disposition")
      assert disposition =~ ~s(filename="Papier Mller.pdf")
      assert disposition =~ "filename*=UTF-8''Papier%20M%C3%BCller.pdf"

      assert "private, no-store" in Plug.Conn.get_resp_header(response, "cache-control")
    end

    test "an admin ruling on the claim can read the frozen file", %{
      admin_conn: conn,
      reporter: reporter,
      attachment: attachment
    } do
      case_record = report!(reporter, attachment)

      # The freeze took it out of every tree this app serves from, so this route
      # is the only way to open it at all.
      assert Repo.get!(Attachment, attachment.id).frozen_at
      refute AttachmentStore.served_path(attachment.token)

      response = get(conn, ~p"/moderation/cases/#{case_record.id}/file")
      assert response.status == 200
      assert response.resp_body != ""
    end

    test "the reporter is not one of the two people who may read it", %{
      reporter_conn: conn,
      reporter: reporter,
      attachment: attachment
    } do
      case_record = report!(reporter, attachment)
      assert get(conn, ~p"/moderation/cases/#{case_record.id}/file").status == 404
    end

    test "a malformed case id is a 404, like every other action", %{author_conn: conn} do
      assert conn |> get("/moderation/cases/not-a-uuid/file") |> html_response(404)
    end
  end

  describe "the two case pages" do
    test "the owner's page links the file and offers the self-service delete", %{
      author_conn: conn,
      reporter: reporter,
      attachment: attachment,
      post: post
    } do
      case_record = report!(reporter, attachment)

      response =
        conn |> get(~p"/moderation/cases/#{case_record.id}") |> html_response(200)

      assert response =~ ~p"/moderation/cases/#{case_record.id}/file"
      assert response =~ ~p"/moderation/cases/#{case_record.id}/delete_content"
      # No edit offer: a file cannot be revised, only taken down or disputed.
      refute response =~ ~p"/posts/#{post.id}/edit"
    end

    test "the admin's page links the file and says what the two rulings do", %{
      admin_conn: conn,
      reporter: reporter,
      attachment: attachment
    } do
      case_record = report!(reporter, attachment)

      html =
        conn |> german() |> get(~p"/admin/moderation/#{case_record.id}") |> html_response(200)

      assert html =~ ~p"/moderation/cases/#{case_record.id}/file"
      assert html =~ "Die gemeldete Datei"
      assert html =~ "samt Vorschauseiten und privatem Original"
      # An upheld case removes the file, never the post it hangs under.
      assert html =~ "Der Beitrag bleibt in beiden Fällen stehen."
    end

    # The ruling panel used to reach the picture's `:deleted` sentence, so an
    # admin about to delete a **file** was told "Das gemeldete Bild wird
    # gelöscht" — the #2067 mistake, found in the browser and not by any of the
    # tests above.
    test "the admin's ruling panel names the file, not a picture", %{
      admin_conn: conn,
      reporter: reporter,
      attachment: attachment
    } do
      case_record = report!(reporter, attachment)

      html =
        conn |> german() |> get(~p"/admin/moderation/#{case_record.id}") |> html_response(200)

      assert html =~ "Die gemeldete Datei wird gelöscht"
      refute html =~ "Das gemeldete Bild wird gelöscht"
    end

    test "the owner's delete removes the file and leaves the post", %{
      author_conn: conn,
      reporter: reporter,
      attachment: attachment,
      post: post
    } do
      case_record = report!(reporter, attachment)

      conn = post(conn, ~p"/moderation/cases/#{case_record.id}/delete_content")

      assert redirected_to(conn) == ~p"/moderation/cases/#{case_record.id}"
      refute Repo.get(Attachment, attachment.id)
      assert Repo.get(Post, post.id)
    end
  end
end
