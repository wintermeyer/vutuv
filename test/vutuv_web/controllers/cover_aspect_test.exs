defmodule VutuvWeb.CoverAspectTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Uploads.Spec
  alias VutuvWeb.UI

  # Issue #1518: the crop dialog framed a cover at 4:1 while the profile banner
  # was a fixed `h-28` box of viewport-dependent width (~6.6:1 on a desktop,
  # ~3:1 on a phone), so the picture a member had just positioned was cropped a
  # second time and differently on every screen. The frame is one shape now, and
  # these tests pin the two ends of that promise together: what the dialog
  # frames (`data-crop-aspect`) and what every rendered cover box is shaped like
  # (`UI.cover_aspect_class/0`).

  defp with_cover(user) do
    {:ok, user} =
      Repo.update(
        Ecto.Changeset.change(user, cover_photo: "cover.jpg", cover_fingerprint: "abc123")
      )

    user
  end

  # The tag carrying `marker`, so an assertion about one box cannot be satisfied
  # by another element on the page.
  defp tag_with(html, marker) do
    with [tag] <- Regex.run(~r/<(?:img|div|input)\b[^>]*#{Regex.escape(marker)}[^>]*>/, html),
         do: tag
  end

  describe "the cover aspect ratio" do
    test "the class and the crop number describe the same shape" do
      {w, h} = UI.cover_aspect()

      assert UI.cover_aspect_class() == "aspect-[#{w}/#{h}]"
      assert Float.parse(UI.cover_crop_aspect()) == {w / h, ""}
      assert UI.cover_aspect_label() == "#{w}:#{h}"
    end

    test "the crop dialog frames the cover at that ratio", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/profile") |> html_response(200)
      input = tag_with(html, ~s(data-crop-target="user_cover_crop"))

      assert input, "expected the cover file input"
      assert input =~ ~s(data-crop-aspect="#{UI.cover_crop_aspect()}")
    end

    test "the profile banner is shaped like the crop frame", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      user = with_cover(user)

      html = conn |> get(~p"/#{user}") |> html_response(200)
      banner = tag_with(html, ~s(data-cover-frame))

      assert banner, "expected the profile cover banner"
      assert banner =~ UI.cover_aspect_class()
      # A fixed height would crop the framed picture a second time, by an amount
      # that depends on how wide the column happens to be.
      refute banner =~ "h-28"
    end

    test "both previews on the settings form are shaped like the crop frame", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      _user = with_cover(user)

      html = conn |> get(~p"/settings/profile") |> html_response(200)

      current = tag_with(html, ~s(alt="Current cover photo"))
      fresh = tag_with(html, ~s(data-crop-preview="user_cover_crop"))

      assert current =~ UI.cover_aspect_class()
      assert fresh =~ UI.cover_aspect_class()
    end
  end

  describe "the recommended upload size" do
    test "the form names it for both pictures", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/profile") |> html_response(200)

      {cover_w, cover_h} = UI.recommended_cover_size()
      {avatar_w, avatar_h} = UI.recommended_avatar_size()

      assert html =~ "#{UI.delimited_count(cover_w)} × #{UI.delimited_count(cover_h)}"
      assert html =~ "#{UI.delimited_count(avatar_w)} × #{UI.delimited_count(avatar_h)}"
      assert html =~ UI.cover_aspect_label()
    end

    # vutuv is a German site, and both sentences carry numbers a formatter
    # groups differently per locale ("1.600" here, "1,600" in English).
    test "it reads as German, with German thousands separators", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html =
        conn
        |> Phoenix.ConnTest.recycle()
        |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
        |> get(~p"/settings/profile")
        |> html_response(200)

      assert html =~ "Empfohlen: 1.600 × 400 Pixel (4:1)."
      assert html =~ "Empfohlen: quadratisch, mindestens 400 × 400 Pixel."
    end

    test "the cover recommendation is the widest version we store, at the banner's shape" do
      {w, h} = UI.recommended_cover_size()
      {aw, ah} = UI.cover_aspect()

      assert w == Spec.max_width(:cover)
      assert h == div(w * ah, aw)
    end

    test "the avatar recommendation leaves room to zoom in" do
      {w, h} = UI.recommended_avatar_size()

      assert w == h
      assert w >= 2 * Spec.max_width(:avatar)
    end
  end
end
