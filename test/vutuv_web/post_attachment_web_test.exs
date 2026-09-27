defmodule VutuvWeb.PostAttachmentWebTest do
  @moduledoc """
  What a published post shows of its files and hands out (issue #2108): a chip
  per file with its name and size, the preview pages as pictures, and the file
  itself at `Vutuv.Attachments.file_url/1` — guarded by the post's audience,
  the way `/post_images` guards its photos.

  Not async: it points the global `:uploads_dir_prefix` at a tmp dir. Every
  file is a PDF so the page is rendered by `pdftoppm`, which has no deadline
  (see `message_attachment_web_test.exs`).
  """

  use VutuvWeb.ConnCase, async: false

  import Vutuv.AttachmentHelpers, only: [settle!: 1]
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Pages
  alias Vutuv.Posts

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_post_file_#{System.unique_integer([:positive])}")
    src = Path.join(tmp, "src")
    File.mkdir_p!(src)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {author_conn, author} = create_and_login_admin(conn)

    {:ok, file} =
      Attachments.create_pending(author, Fixtures.plain_pdf(src), "Preisliste 2026.pdf")

    file = settle!(file)

    %{author: author, author_conn: author_conn, upload: file}
  end

  defp publish!(author, file, attrs \\ %{}) do
    {:ok, post} =
      Posts.create_post(author, Map.merge(%{body: "Mit Datei", attachment_ids: [file.id]}, attrs))

    post
  end

  defp page_url(file), do: Attachments.page_url(file, hd(Pages.list(file)), "thumb")

  describe "a public post" do
    setup %{author: author, upload: file}, do: %{post: publish!(author, file)}

    test "shows a chip and the preview page on its permalink", %{post: post, upload: file} do
      html = build_conn() |> get(Posts.path(post)) |> html_response(200)

      assert html =~ ~s(data-post-file="#{file.id}")
      assert html =~ "Preisliste 2026.pdf"
      assert html =~ Attachments.file_url(file)
      assert html =~ page_url(file)
    end

    test "hands the file to an anonymous reader as a download", %{upload: file} do
      conn = build_conn() |> get(Attachments.file_url(file))

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert get_resp_header(conn, "content-type") == ["application/pdf"]
    end

    test "lists the file in its agent formats", %{post: post, upload: file} do
      url = VutuvWeb.AgentDocs.abs_url(Attachments.file_url(file))

      for ext <- ~w(md txt) do
        text = build_conn() |> get(Posts.path(post) <> "." <> ext) |> response(200)
        assert text =~ "Preisliste 2026.pdf"
        assert text =~ url
      end

      json = build_conn() |> get(Posts.path(post) <> ".json") |> json_response(200)
      assert [%{"name" => "Preisliste 2026.pdf", "url" => ^url}] = json["files"]
    end

    test "serves its preview page to an anonymous reader", %{upload: file} do
      conn = build_conn() |> get(page_url(file))

      assert conn.status == 200
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "image/"
    end
  end

  describe "a post for logged-in members only" do
    setup %{author: author, upload: file} do
      %{post: publish!(author, file, %{denials: [%{"wildcard" => "logged_out"}]})}
    end

    test "keeps the file and its pages from an anonymous reader", %{upload: file} do
      assert build_conn() |> get(Attachments.file_url(file)) |> response(404)
      assert build_conn() |> get(page_url(file)) |> response(404)
    end

    test "still hands them to a member", %{conn: conn, upload: file} do
      {member_conn, _member} = create_and_login_user(conn)

      assert member_conn |> get(Attachments.file_url(file)) |> response(200)
    end
  end

  test "a frozen file is out of reach and off the card", %{author: author, upload: file} do
    post = publish!(author, file)
    :ok = Attachments.freeze(Vutuv.Repo.reload!(file))

    assert build_conn() |> get(Attachments.file_url(file)) |> response(404)

    html = build_conn() |> get(Posts.path(post)) |> html_response(200)
    refute html =~ ~s(data-post-file="#{file.id}")
  end

  test "the data export names the post's files", %{author: author, upload: file} do
    post = publish!(author, file)

    assert [%{files: [exported]}] =
             Vutuv.Export.build(author).posts |> Enum.filter(&(&1.id == post.id))

    assert exported.name == "Preisliste 2026.pdf"
    assert exported.content_type == "application/pdf"
    assert exported.url == VutuvWeb.Endpoint.url() <> Attachments.file_url(file)
  end

  test "deleting the account takes the files off the disk", %{author: author, upload: file} do
    publish!(author, file)
    assert Vutuv.AttachmentStore.served_path(file.token)
    assert Vutuv.AttachmentStore.original_path(file.token)

    {:ok, _deleted} = Vutuv.Accounts.delete_user(author)

    refute Vutuv.AttachmentStore.served_path(file.token)
    refute Vutuv.AttachmentStore.original_path(file.token)
    assert build_conn() |> get(Attachments.file_url(file)) |> response(404)
  end

  test "the post's German card says what the chip offers", %{author: author, upload: file} do
    post = publish!(author, file)

    html =
      build_conn()
      |> put_req_header("accept-language", "de-DE,de")
      |> get(Posts.path(post))
      |> html_response(200)

    assert html =~ "Datei herunterladen"
  end
end
