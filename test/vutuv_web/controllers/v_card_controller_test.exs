defmodule VutuvWeb.VCardControllerTest do
  # Not async: the "with an avatar" regression test sets the global
  # `:uploads_dir_prefix` application env (same constraint as Vutuv.AvatarTest).
  use VutuvWeb.ConnCase, async: false

  setup do
    user = insert_activated_user(username: "vcard-tester")
    %{user: user}
  end

  test "GET vcard returns a 200 text/vcard body" do
    conn = get(build_conn(), "/vcard-tester/vcard")

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
    conn = get(build_conn(), "/vcard-tester/vcard")

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

    # Record the uploaded avatar and place the original where Vutuv.Avatar
    # derives the vCard JPEG from: <prefix>/originals/avatars/<id>/original.jpg
    user = user |> Ecto.Changeset.change(avatar: "selfie.jpg") |> Repo.update!()
    dir = Path.join(tmp, "originals/avatars/#{user.id}")
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(300, 200, color: [1, 2, 3])
    {:ok, _} = Image.write(img, Path.join(dir, "original.jpg"))

    conn = get(build_conn(), "/vcard-tester/vcard")

    assert conn.status == 200
    assert conn.resp_body =~ "PHOTO;ENCODING=b;TYPE=JPEG:"
  end

  test "the owner's own session vCard download carries their private addresses", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    insert(:email, user: owner, value: "secret@example.com", public?: false)

    body = conn |> get("/#{owner.username}/vcard") |> response(200)
    assert body =~ "secret@example.com"
  end

  test "the session vCard hides private addresses from a member the owner follows", %{conn: conn} do
    # Owner-only privacy: even a vernetzte viewer (mutual follow) must not get
    # the private address in the session-aware vCard. Public addresses live on
    # the cache-safe /:slug.vcf, so a permitted-but-not-owner viewer gets none.
    owner = insert_activated_user(username: "vcard-private-owner")
    insert(:email, user: owner, value: "secret@example.com", public?: false)

    {conn, viewer} = create_and_login_user(conn)
    insert(:follow, follower: owner, followee: viewer)
    insert(:follow, follower: viewer, followee: owner)

    body = conn |> get("/#{owner.username}/vcard") |> response(200)
    refute body =~ "secret@example.com"
  end

  test "the N field carries all five components incl. the honorific suffix" do
    insert_activated_user(
      username: "phd-tester",
      first_name: "Ada",
      last_name: "Lovelace",
      honorific_prefix: "Dr.",
      honorific_suffix: "PhD"
    )

    conn = get(build_conn(), "/phd-tester/vcard")
    n_line = conn.resp_body |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "N:"))

    # vCard N is Family;Given;Additional;Prefix;Suffix — the suffix must not be
    # dropped, and FN must be the full display name, not just "first last".
    assert n_line == "N:Lovelace;Ada;;Dr.;PhD"
    assert conn.resp_body =~ "FN:Dr. Ada Lovelace PhD"
  end
end
