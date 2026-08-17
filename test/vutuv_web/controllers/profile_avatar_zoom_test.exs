defmodule VutuvWeb.ProfileAvatarZoomTest do
  @moduledoc """
  Issue #1528: clicking a profile picture opens it at full size in the photo
  lightbox. The picture behind that click is the `:large` version
  (`Vutuv.Uploads.Spec`), which is younger than the rows — so the link has to
  appear only once the file is really on disk, and the header has to look
  exactly as it did before until then.

  Not async: it points `:uploads_dir_prefix` at a temp tree so the derived files
  are not written into the checkout. That key is global and the SQL sandbox does
  not roll it back; every uploader in `lib/vutuv/uploaders/*` reads it through
  `Vutuv.Uploads.disk_dir/1`, so it lives in its own sync file.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Uploads.Spec

  @fingerprint "abc123def456"

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_avatar_zoom_#{System.unique_integer([:positive])}")
    previous = Application.fetch_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      case previous do
        {:ok, was} -> Application.put_env(:vutuv, :uploads_dir_prefix, was)
        :error -> Application.delete_env(:vutuv, :uploads_dir_prefix)
      end
    end)

    {:ok, tmp: tmp}
  end

  # A member with an avatar whose derived files are exactly `versions` — which
  # is how a row looks between the deploy that adds a version and the
  # regeneration that derives it.
  defp with_avatar(user, tmp, versions) do
    {:ok, user} =
      Repo.update(
        change(user, avatar: "me.png", avatar_fingerprint: @fingerprint, avatar_moderation: nil)
      )

    dir = Path.join(tmp, "avatars/#{user.id}")
    File.mkdir_p!(dir)

    for version <- versions do
      File.write!(Path.join(dir, "#{user.username}-#{version}-#{@fingerprint}.avif"), "avif")
    end

    user
  end

  defp zoom_link(html) do
    with [tag] <- Regex.run(~r/<a\b[^>]*id="profile-avatar-zoom"[^>]*>/, html), do: tag
  end

  describe "the profile picture opens larger" do
    test "the header avatar links into the lightbox once :large exists", %{conn: conn, tmp: tmp} do
      user = with_avatar(insert_activated_user(), tmp, ~w(thumb medium large))

      html = conn |> get(~p"/#{user}") |> html_response(200)
      link = zoom_link(html)

      assert link, "expected the profile picture to be a lightbox link"
      assert link =~ ~s(href="/avatars/#{user.id}/#{user.username}-large-#{@fingerprint}.avif")
      assert link =~ ~s(data-lightbox-photo="0")
      # The overlay reads what it shows off the link, so the same URL rides
      # `data-photo-src` — a href alone is only the no-JavaScript path.
      assert link =~ ~s(data-photo-src="/avatars/#{user.id}/)
      # ...and the lightbox JS only opens links that sit in a gallery.
      assert html =~ "data-lightbox-gallery"
    end

    test "an avatar with no :large file yet is not a link", %{conn: conn, tmp: tmp} do
      user = with_avatar(insert_activated_user(), tmp, ~w(thumb medium))

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute zoom_link(html), "an avatar with nothing bigger to open must not be clickable"
      # The picture itself is untouched — only the click is missing.
      assert html =~ "#{user.username}-medium-#{@fingerprint}.avif"
    end

    test "a member with no picture at all is not a link", %{conn: conn} do
      user = insert_activated_user()

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute zoom_link(html)
    end

    test "the picture is named in the reader's language", %{conn: conn, tmp: tmp} do
      user = with_avatar(insert_activated_user(), tmp, ~w(thumb medium large))

      html =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/#{user}")
        |> html_response(200)

      assert html =~ "Profilbild größer anzeigen"
      assert html =~ "Profilbild von #{VutuvWeb.UserHelpers.full_name(user)}"
    end
  end

  describe "the owner's picture while the AI scan runs" do
    test "the quarantine preview is what opens, and only once :large is there", %{
      conn: conn,
      tmp: tmp
    } do
      {conn, user} = create_and_login_user(conn)
      user = with_avatar(user, tmp, [])

      {:ok, user} = Repo.update(change(user, avatar_moderation: "pending"))

      quarantine = Path.join(tmp, "quarantine/avatars/#{user.id}")
      File.mkdir_p!(quarantine)

      html = conn |> get(~p"/#{user}") |> html_response(200)
      refute zoom_link(html), "nothing is derived yet, so there is nothing to open"

      File.write!(
        Path.join(quarantine, "#{user.username}-large-#{@fingerprint}.avif"),
        "avif"
      )

      link = conn |> get(~p"/#{user}") |> html_response(200) |> zoom_link()

      assert link
      assert link =~ ~s(href="/settings/pending_image/avatar/large")
    end

    test "the pending-preview route serves every version the spec defines", %{
      conn: conn,
      tmp: tmp
    } do
      {conn, user} = create_and_login_user(conn)
      user = with_avatar(user, tmp, [])
      {:ok, user} = Repo.update(change(user, avatar_moderation: "pending"))

      quarantine = Path.join(tmp, "quarantine/avatars/#{user.id}")
      File.mkdir_p!(quarantine)

      for spec <- Spec.versions(:avatar) do
        File.write!(
          Path.join(quarantine, "#{user.username}-#{spec.name}-#{@fingerprint}.avif"),
          "avif"
        )

        response =
          conn
          |> Phoenix.ConnTest.recycle()
          |> get(~p"/settings/pending_image/avatar/#{spec.name}")

        assert response.status == 200, "the owner cannot preview their pending #{spec.name}"
      end
    end
  end
end
