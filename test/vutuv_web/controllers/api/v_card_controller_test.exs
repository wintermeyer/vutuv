defmodule VutuvWeb.Api.VCardControllerTest do
  # Not async: the "with an avatar" regression test sets the global
  # `:uploads_dir_prefix` application env (same constraint as Vutuv.AvatarTest).
  use VutuvWeb.ConnCase, async: false

  setup do
    user = insert_validated_user(active_slug: "vcard-tester")
    %{user: user}
  end

  test "GET vcard returns a 200 text/vcard body" do
    conn = get(build_conn(), "/api/1.0/users/vcard-tester/vcard")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/vcard"
    assert conn.resp_body =~ "BEGIN:VCARD"
    assert conn.resp_body =~ "END:VCARD"
  end

  # Regression test for issue #749: a user who never uploaded a profile picture
  # must not get the default placeholder embedded in their vCard. The default
  # avatar is an inline SVG data URI, which is intentionally never emitted as a
  # PHOTO line (the vCard PHOTO field only carries the uploaded JPEG/PNG).
  test "omits the PHOTO line when the user has no profile picture" do
    conn = get(build_conn(), "/api/1.0/users/vcard-tester/vcard")

    assert conn.status == 200
    refute conn.resp_body =~ "PHOTO"
    refute conn.resp_body =~ "svg"
  end

  test "includes a base64 PHOTO line when the user has an avatar", %{user: user} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_vcard_test_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    # Record the uploaded avatar and place the thumb where Vutuv.Avatar expects
    # it: <prefix>/avatars/<id>/<First Last>_thumb.jpg
    user = user |> Ecto.Changeset.change(avatar: "selfie.jpg") |> Repo.update!()
    dir = Path.join(tmp, "avatars/#{user.id}")
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
    {:ok, _} = Image.write(img, Path.join(dir, "#{user}_thumb.jpg"))

    conn = get(build_conn(), "/api/1.0/users/vcard-tester/vcard")

    assert conn.status == 200
    assert conn.resp_body =~ "PHOTO;ENCODING=b;TYPE=JPEG:"
  end
end
