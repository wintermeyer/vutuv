defmodule VutuvWeb.ImageReportTest do
  @moduledoc """
  Reporting a profile picture in its own right (issue #2012): the way in from
  the profile, the form that shows which picture it is, and the two case pages
  that are the only place a held picture can still be looked at.

  Not async: points the global `:uploads_dir_prefix` at a tmp dir, which every
  uploader reads.
  """

  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Accounts
  alias Vutuv.Images
  alias Vutuv.Moderation

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_image_report_#{System.unique_integer([:positive])}")

    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    # All three logins here, in one order: each drives the real PIN flow and
    # reads the newest mail out of this process's mailbox, so interleaving them
    # with a test's own logins hands one of them somebody else's PIN.
    {owner_conn, owner} = create_and_login_user(conn)
    {reporter_conn, reporter} = create_and_login_user(conn)
    {admin_conn, _admin} = create_and_login_admin(conn)

    {:ok, owner} = Accounts.update_user(owner, %{avatar: jpeg_upload()})

    {:ok,
     owner_conn: owner_conn,
     reporter_conn: reporter_conn,
     admin_conn: admin_conn,
     owner: owner,
     reporter: reporter,
     image: Images.profile_image(owner.id, "avatar")}
  end

  defp jpeg_upload(name \\ "selfie.jpg") do
    src = Path.join(System.tmp_dir!(), "report_src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(300, 200, color: [10, 120, 200])
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)
    %Plug.Upload{filename: name, path: src, content_type: "image/jpeg"}
  end

  defp report!(reporter, image) do
    {:ok, case_record} =
      Moderation.report_content(reporter, image, %{
        "category" => "copyright",
        "note" => "That is my photograph.",
        "good_faith?" => "true"
      })

    case_record
  end

  describe "the way in" do
    test "the profile's menu offers to report the picture itself", %{
      reporter_conn: conn,
      owner: owner,
      image: image
    } do
      html = conn |> get(~p"/#{owner}") |> html_response(200)

      assert html =~ "id=\"report-avatar\""
      assert html =~ "type=image&amp;id=#{image.id}"
    end

    test "the form shows which picture it is, and offers the copyright notice", %{
      reporter_conn: conn,
      image: image
    } do
      html =
        conn
        |> get(~p"/reports/new?#{[type: "image", id: image.id]}")
        |> html_response(200)

      # The picture, not a sentence about it: a rights holder has to see what
      # they are about to file a legal notice over.
      assert html =~ "/avatars/#{image.user_id}/"
      assert html =~ "value=\"copyright\""
    end

    test "the German form says what it is", %{reporter_conn: conn, image: image} do
      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/reports/new?#{[type: "image", id: image.id]}")
        |> html_response(200)

      assert html =~ "Profilbild"
    end
  end

  describe "the case pages" do
    test "the owner sees the held picture, and it answers on its own route", %{
      owner_conn: conn,
      owner: owner,
      reporter: reporter
    } do
      case_record = report!(reporter, Images.profile_image(owner.id, "avatar"))

      html = conn |> get(~p"/moderation/cases/#{case_record.id}") |> html_response(200)

      assert html =~ "id=\"case-image\""
      assert html =~ "/moderation/cases/#{case_record.id}/image"

      # And the picture really is served there, which while the case runs is
      # the only place it is reachable at all.
      assert conn
             |> recycle()
             |> get(~p"/moderation/cases/#{case_record.id}/image")
             |> response(200) != ""
    end

    test "a stranger gets nothing from the picture route", %{
      reporter_conn: conn,
      owner: owner,
      reporter: reporter
    } do
      case_record = report!(reporter, Images.profile_image(owner.id, "avatar"))

      conn
      |> get(~p"/moderation/cases/#{case_record.id}/image")
      |> response(404)
    end

    test "an admin sees it", %{admin_conn: conn, owner: owner, reporter: reporter} do
      case_record = report!(reporter, Images.profile_image(owner.id, "avatar"))

      conn
      |> get(~p"/moderation/cases/#{case_record.id}/image")
      |> response(200)
    end
  end

  describe "the profile while a picture is held" do
    test "shows the silhouette, and the actor document stops naming a picture", %{
      conn: conn,
      owner: owner,
      reporter: reporter
    } do
      {:ok, owner} = Accounts.update_user(owner, %{"fediverse_followers?" => true})
      report!(reporter, Images.profile_image(owner.id, "avatar"))

      refute conn |> get(~p"/#{owner}") |> html_response(200) =~ "/avatars/#{owner.id}/"

      actor =
        conn
        |> recycle()
        |> put_req_header("accept", "application/activity+json")
        |> get(~p"/#{owner}")
        |> json_response(200)

      refute Map.has_key?(actor, "icon")
    end

    test "the member is told why their new upload was refused", %{
      owner_conn: conn,
      owner: owner,
      reporter: reporter
    } do
      report!(reporter, Images.profile_image(owner.id, "avatar"))

      conn =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> put(~p"/settings/profile", %{"user" => %{"avatar" => jpeg_upload("neu.jpg")}})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Profilbild"
    end
  end
end
