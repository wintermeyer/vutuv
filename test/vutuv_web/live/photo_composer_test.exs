defmodule VutuvWeb.PhotoComposerTest do
  @moduledoc """
  The composer's photo strip and per-photo panel (issue #1104).

  Photos are put in through the **real upload path** — a crafted JPEG through
  `live_file_input` — rather than by inserting rows, because half of what is
  asserted here depends on what the upload parsed out of the file: whether
  there are camera settings to offer, and whether the photo carries a location
  worth warning about.

  The guiding claim of the feature is that everything beyond "drop photos and
  press Post" is one switch, so much of what is asserted is what does **not**
  appear: no panel until you ask for one, no licence select on a text post, no
  exact-file choice until a download is offered.
  """

  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vix.Vips.MutableImage
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Repo

  setup do
    # Uploads land in the checkout otherwise (the prefix is empty outside
    # production), so every test gets its own throwaway tree.
    tmp = Path.join(System.tmp_dir!(), "vutuv_photo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    :ok
  end

  # A real JPEG carrying whatever EXIF the test needs. `exif:` takes the
  # libvips header names, so a test can hand the upload a camera, a location,
  # or nothing at all.
  defp jpeg(opts) do
    {:ok, img} = Image.new(Keyword.get(opts, :width, 90), 60, color: [30, 90, 160])

    {:ok, tagged} =
      Image.mutate(img, fn mut ->
        Enum.each(Keyword.get(opts, :exif, []), fn {name, value} ->
          :ok = MutableImage.set(mut, name, :gchararray, value)
        end)
      end)

    {:ok, binary} = Image.write(tagged, :memory, suffix: ".jpg")
    binary
  end

  defp open_composer(conn) do
    {:ok, live, _html} = live(conn, ~p"/feed")
    live |> element("#open-composer") |> render_click()
    live
  end

  # Drives one photo through the composer's own upload and returns the row it
  # created, so a test can address its tile and panel by id.
  defp upload_photo!(live, user, opts \\ []) do
    content = jpeg(opts)
    name = "photo-#{System.unique_integer([:positive])}.jpg"

    input =
      file_input(live, "#composer-form", :images, [
        %{name: name, content: content, type: "image/jpeg", size: byte_size(content)}
      ])

    render_upload(input, name)
    newest_pending(user)
  end

  defp newest_pending(user) do
    import Ecto.Query

    Repo.one!(
      from(i in PostImage,
        where: i.user_id == ^user.id and is_nil(i.post_id),
        order_by: [desc: i.id],
        limit: 1
      )
    )
  end

  defp open_panel(live, image) do
    live |> element(~s([phx-click="photo-open"][phx-value-id="#{image.id}"])) |> render_click()
  end

  defp toggle(live, image, field) do
    live
    |> element(
      ~s([phx-click="photo-toggle"][phx-value-id="#{image.id}"][phx-value-field="#{field}"])
    )
    |> render_click()
  end

  defp reload(image), do: Repo.get(PostImage, image.id)

  # The post the composer just saved, with its photos in stored order (the
  # schema's `preload_order`, which is what the mosaic reads).
  defp only_post(user) do
    import Ecto.Query

    Post
    |> where([p], p.user_id == ^user.id)
    |> Repo.one!()
    |> Repo.preload(:images)
  end

  describe "a text post" do
    test "shows no photo controls at all", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      live = open_composer(conn)

      refute render(live) =~ "data-photo-tile"
      # The licence select is about photos; on a text post it would be a
      # control about nothing.
      refute has_element?(live, "#composer-license")
    end
  end

  describe "the panel" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user, live: open_composer(conn)}
    end

    test "stays closed until the author asks for it", %{live: live, user: user} do
      image = upload_photo!(live, user)

      refute has_element?(live, "#composer-photo-panel")

      open_panel(live, image)

      assert has_element?(live, "#composer-photo-panel")
    end

    test "the same button closes it again", %{live: live, user: user} do
      image = upload_photo!(live, user)

      open_panel(live, image)
      open_panel(live, image)

      refute has_element?(live, "#composer-photo-panel")
    end

    test "the camera switch is disabled and explains itself when the file carries nothing", %{
      live: live,
      user: user
    } do
      image = upload_photo!(live, user)
      open_panel(live, image)

      assert render(live) =~ "This file carries no camera information."
      assert has_element?(live, "input[data-photo-camera-switch][disabled]")
    end

    test "the camera switch offers the very line visitors would see", %{live: live, user: user} do
      image =
        upload_photo!(live, user,
          exif: [
            {"exif-ifd0-Make", "Canon"},
            {"exif-ifd0-Model", "Canon EOS R6"},
            {"exif-ifd2-FocalLength", "50/1"},
            {"exif-ifd2-FNumber", "18/10"},
            {"exif-ifd2-ExposureTime", "1/200"},
            {"exif-ifd2-ISOSpeedRatings", "400"}
          ]
        )

      open_panel(live, image)

      assert render(live) =~ "Canon EOS R6 · 50 mm · f/1.8 · 1/200 s · ISO 400"
      refute has_element?(live, "input[data-photo-camera-switch][disabled]")
    end

    test "the exact-file choice appears only once a download is offered", %{
      live: live,
      user: user
    } do
      image = upload_photo!(live, user)
      open_panel(live, image)

      refute render(live) =~ "The file exactly as I uploaded it"

      toggle(live, image, "download_original")

      html = render(live)
      assert html =~ "The file exactly as I uploaded it"
      assert html =~ "Just the picture"
    end

    test "a photo carrying a location warns only when the exact file is picked", %{
      live: live,
      user: user
    } do
      image = upload_photo!(live, user, exif: [{"exif-ifd3-GPSLatitude", "50/1 56/1 0/1"}])
      assert image.has_gps

      open_panel(live, image)
      toggle(live, image, "download_original")

      # The safe choice is the default, and it carries no alarm.
      refute has_element?(live, "[data-photo-gps-warning]")

      live
      |> element(
        ~s([phx-click="photo-exact"][phx-value-id="#{image.id}"][phx-value-exact="true"])
      )
      |> render_click()

      assert has_element?(live, "[data-photo-gps-warning]")
    end

    test "a photo with no location never warns, whatever is picked", %{live: live, user: user} do
      image = upload_photo!(live, user)
      refute image.has_gps

      open_panel(live, image)
      toggle(live, image, "download_original")

      live
      |> element(
        ~s([phx-click="photo-exact"][phx-value-id="#{image.id}"][phx-value-exact="true"])
      )
      |> render_click()

      refute has_element?(live, "[data-photo-gps-warning]")
    end

    test "apply-to-all copies the switches but never the caption", %{live: live, user: user} do
      first = upload_photo!(live, user)
      second = upload_photo!(live, user)

      open_panel(live, first)

      live
      |> form("#composer-form", %{"photo" => %{first.id => %{"caption" => "Only mine"}}})
      |> render_change()

      toggle(live, first, "download_original")
      live |> element("[data-photo-apply-all]") |> render_click()
      live |> form("#composer-form", %{"post" => %{"body" => "Two photos."}}) |> render_submit()

      assert %{download_original: true, caption: "Only mine"} = reload(first)
      # The switch travelled; the caption, which describes one particular
      # picture, did not.
      assert %{download_original: true, caption: nil} = reload(second)
    end

    test "the alt-text nudge disappears once a description is written", %{
      live: live,
      user: user
    } do
      image = upload_photo!(live, user)

      assert has_element?(live, ~s([data-photo-alt-missing="#{image.id}"]))

      open_panel(live, image)

      live
      |> form("#composer-form", %{"photo" => %{image.id => %{"alt" => "A blue rectangle"}}})
      |> render_change()

      refute has_element?(live, ~s([data-photo-alt-missing="#{image.id}"]))
    end
  end

  describe "the licence" do
    test "appears once a photo is attached and is remembered for next time", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      live = open_composer(conn)
      upload_photo!(live, user)

      assert has_element?(live, "#composer-license")

      live
      |> form("#composer-form", %{"post" => %{"body" => "A photo.", "license" => "cc-by-4.0"}})
      |> render_submit()

      post = only_post(user)
      assert post.license == "cc-by-4.0"
      assert Vutuv.Accounts.User |> Repo.get(user.id) |> Posts.default_license() == "cc-by-4.0"
    end
  end

  describe "reordering" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user, live: open_composer(conn)}
    end

    test "the arrows move a photo, and the first one leads the mosaic", %{
      live: live,
      user: user
    } do
      first = upload_photo!(live, user)
      second = upload_photo!(live, user)

      live
      |> element(~s([phx-click="photo-move"][phx-value-id="#{second.id}"][phx-value-dir="back"]))
      |> render_click()

      live |> form("#composer-form", %{"post" => %{"body" => "Two."}}) |> render_submit()

      post = only_post(user)
      assert Enum.map(post.images, & &1.id) == [second.id, first.id]
    end

    test "a drag order naming an unknown photo cannot drop photos from the post", %{
      live: live,
      user: user
    } do
      first = upload_photo!(live, user)
      second = upload_photo!(live, user)

      # Through the strip element, not the view: the composer is a
      # LiveComponent, and the hook pushes with pushEventTo for that reason.
      live
      |> element("#composer-images")
      |> render_hook("photo-reorder", %{"order" => [second.id, "not-a-real-id"]})

      live |> form("#composer-form", %{"post" => %{"body" => "Two."}}) |> render_submit()

      post = only_post(user)
      assert Enum.sort(Enum.map(post.images, & &1.id)) == Enum.sort([first.id, second.id])
    end
  end
end
