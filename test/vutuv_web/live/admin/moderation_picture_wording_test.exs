defmodule VutuvWeb.Admin.ModerationPictureWordingTest do
  @moduledoc """
  What the two case pages say about a reported picture, rendered (issue #2067).

  The three sentences here are decided by helpers in `Vutuv.Moderation` and
  covered as helpers in `Vutuv.ModerationNoticeWordingTest`; what only a render
  can show is that the page picks the right one — and each of them was picked
  wrongly by a page that had no way to ask. The owner's page explained an
  anonymous notice as a member's report; the admin's page explained a picture
  that a copyright case had not hidden with "only a copyright notice takes one
  offline before a ruling", and offered a ruling that "the content stays hidden"
  on a picture that is not hidden and that upholding deletes.

  German, because that is the language the report was written in
  (`Accept-Language: de-DE,de`) and because a fuzzy-filled msgid fails no build.

  Not async: flips the global `:uploads_dir_prefix` for a real picture.
  """

  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.{Accounts, Images, Moderation}

  setup %{conn: conn} do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_picture_wording_#{System.unique_integer([:positive])}")

    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {admin_conn, _admin} = create_and_login_admin(conn)
    {owner_conn, owner} = create_and_login_user(conn)
    {:ok, owner} = Accounts.update_user(owner, %{avatar: jpeg_upload()})

    {:ok,
     conn: admin_conn,
     owner_conn: owner_conn,
     owner: owner,
     image: Images.member_image(owner, "avatar")}
  end

  defp jpeg_upload do
    src = Path.join(System.tmp_dir!(), "wording_src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(120, 90, color: [200, 40, 40])
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)
    %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
  end

  # `recycle/1` first: the login already sent a response on this conn, and a
  # header cannot be put on a sent one.
  defp german(conn),
    do: conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

  defp outside_notice!(content) do
    {:ok, case_record, _report, token} =
      Moderation.file_public_notice(content, %{
        "category" => "copyright",
        "note" => "Das Foto ist meins.",
        "good_faith?" => "true",
        "reporter_name" => "Rita Holder",
        "reporter_email" => "rita@example.com"
      })

    {case_record, token}
  end

  describe "the admin case page on a picture nothing has hidden" do
    test "names the unconfirmed address, not the category", %{conn: conn, image: image} do
      {case_record, _token} = outside_notice!(image)

      html =
        conn |> german() |> get(~p"/admin/moderation/#{case_record.id}") |> html_response(200)

      assert html =~ "Die Adresse hinter der Urheberrechtsmeldung ist noch nicht bestätigt"
      refute html =~ "Nur eine Meldung wegen Urheberrechts nimmt ein Bild"
    end

    test "says the ruling deletes rather than hides", %{conn: conn, image: image} do
      {case_record, _token} = outside_notice!(image)

      html =
        conn |> german() |> get(~p"/admin/moderation/#{case_record.id}") |> html_response(200)

      assert html =~ "Das gemeldete Bild wird gelöscht, auch das private Original"
      refute html =~ "Der Inhalt bleibt verborgen und der Besitzer erhält"
    end
  end

  describe "the owner's case page" do
    test "does not invent a member behind an anonymous notice", %{
      owner_conn: conn,
      image: image
    } do
      {case_record, token} = outside_notice!(image)
      {:ok, :confirmed, _report} = Moderation.confirm_public_notice(token)

      html =
        conn |> german() |> get(~p"/moderation/cases/#{case_record.id}") |> html_response(200)

      assert html =~ "Die Meldung einer Person mit guter Bilanz"
      refute html =~ "Die Meldung eines Mitglieds mit guter Bilanz"
    end

    test "keeps the member wording for a member's report", %{owner_conn: conn, owner: owner} do
      reporter = insert_activated_user()
      post = insert(:post, user: owner)
      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "bullying"})

      html =
        conn |> german() |> get(~p"/moderation/cases/#{case_record.id}") |> html_response(200)

      assert html =~ "Die Meldung eines Mitglieds mit guter Bilanz"
    end
  end
end
