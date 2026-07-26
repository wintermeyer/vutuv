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

  defp open_photo_composer(conn) do
    {:ok, live, _html} = live(conn, ~p"/feed")
    live |> element("#open-photo-composer") |> render_click()
    live
  end

  # A pending row minted outside any composer — the shape a reconnected
  # composer finds in the DB when form recovery hands its ids back.
  defp pending_image!(user, opts \\ []) do
    path =
      Path.join(
        System.tmp_dir!(),
        "vutuv_pending_#{System.unique_integer([:positive])}.jpg"
      )

    File.write!(path, jpeg(opts))
    {:ok, image} = Posts.create_pending_image(user, path, Path.basename(path))
    File.rm(path)
    image
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
    # The scrim's ⚙ specifically — the tile's img opens the panel too now,
    # so a bare [phx-click=photo-open] selector matches two elements.
    live
    |> element(~s(button[phx-click="photo-open"][phx-value-id="#{image.id}"]))
    |> render_click()
  end

  defp toggle(live, image, field) do
    live
    |> element(
      ~s([phx-click="photo-toggle"][phx-value-id="#{image.id}"][phx-value-field="#{field}"])
    )
    |> render_click()
  end

  # The post-wide download select carries its own phx-change (not the form's),
  # so a test drives it through the element rather than through `form/3`.
  defp choose_download(live, choice) do
    live
    |> element("#composer-download")
    |> render_change(%{"post" => %{"download" => choice}})
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

    test "one photo gets no download switch: the post-wide select is its answer", %{
      live: live,
      user: user
    } do
      # Two controls for one state on one screen is the duplicate the photo
      # grid keeps being cleaned of; the panel's switch is the OVERRIDE, so it
      # only means something once there is a set to differ from.
      image = upload_photo!(live, user)
      open_panel(live, image)

      refute has_element?(live, "input[data-photo-download-switch]")

      upload_photo!(live, user)

      assert has_element?(live, "input[data-photo-download-switch]")
    end

    test "the exact-file choice appears only once a download is offered", %{
      live: live,
      user: user
    } do
      image = upload_photo!(live, user)
      upload_photo!(live, user)
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
      upload_photo!(live, user)

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
      upload_photo!(live, user)

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

  describe "the two composer modes (photo-first vs. text-first)" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "the composer opens text-first by default", %{conn: conn} do
      live = open_composer(conn)

      assert has_element?(live, ~s(#composer[data-composer-mode="text"]))
      refute has_element?(live, "[data-photo-dropzone]")
    end

    test "the feed's camera trigger opens the composer photo-first", %{conn: conn} do
      live = open_photo_composer(conn)

      assert has_element?(live, ~s(#composer[data-composer-mode="photos"]))
      # Photos lead: a real dropzone up top, no book/film noise, and the text
      # editor waits behind one button instead of headlining the panel.
      assert has_element?(live, "[data-photo-dropzone]")
      refute has_element?(live, ~s(button[phx-click="review-kind"]))
      assert has_element?(live, "#composer-add-text")
      refute has_element?(live, ~s(#composer-form textarea[name="post[body]"]))
    end

    test "photo mode shows one caption per photo; the alt text lives in the panel", %{
      conn: conn,
      user: user
    } do
      live = open_photo_composer(conn)
      image = upload_photo!(live, user)

      assert has_element?(live, ~s(input[name="photo[#{image.id}][caption]"]))
      # One visible text per photo: the caption already serves as the
      # accessible name when no alt is written, so the alt input is the
      # panel's opt-in refinement rather than a second required-looking field.
      refute has_element?(live, ~s(input[name="photo[#{image.id}][alt]"]))

      open_panel(live, image)

      assert has_element?(live, "#composer-photo-panel")
      assert has_element?(live, ~s(input[name="photo[#{image.id}][alt]"]))

      # The open panel must not render a second caption field (two same-name
      # inputs corrupt the submit).
      assert live
             |> render()
             |> then(fn html ->
               length(String.split(html, ~s(name="photo[#{image.id}][caption]"))) == 2
             end)
    end

    test "a photo carrying camera facts offers the publish switch right under its tile", %{
      conn: conn,
      user: user
    } do
      live = open_photo_composer(conn)

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

      assert has_element?(live, ~s([data-photo-camera-inline="#{image.id}"]))
      assert render(live) =~ "Canon EOS R6 · 50 mm · f/1.8 · 1/200 s · ISO 400"

      live
      |> element(~s([data-photo-camera-inline="#{image.id}"] input[phx-click="photo-toggle"]))
      |> render_click()

      live |> form("#composer-form", %{"post" => %{"mode" => "photos"}}) |> render_submit()

      assert %{show_camera_info: true} = reload(image)
    end

    test "a photo without camera facts gets no camera row", %{conn: conn, user: user} do
      live = open_photo_composer(conn)
      image = upload_photo!(live, user)

      refute has_element?(live, ~s([data-photo-camera-inline="#{image.id}"]))
    end

    test "tapping the photo itself opens its options panel", %{conn: conn, user: user} do
      # The picture is the biggest target on screen and the first thing
      # people try — it IS the options button (a real <button>, so the
      # keyboard reaches it too; the old scrim ⚙ is gone).
      live = open_photo_composer(conn)
      image = upload_photo!(live, user)

      refute has_element?(live, "#composer-photo-panel")

      open_panel(live, image)

      assert has_element?(live, "#composer-photo-panel")
    end

    test "a single photo carries no reorder arrows, just remove and the photo itself", %{
      conn: conn,
      user: user
    } do
      # With one photo there is no order to change: the ◀ ▶ pair would be two
      # dead ghost buttons (Stefan: do we need these at all?).
      live = open_photo_composer(conn)
      image = upload_photo!(live, user)

      refute has_element?(live, ~s([phx-click="photo-move"]))
      assert has_element?(live, ~s(button[phx-click="remove-image"][phx-value-id="#{image.id}"]))

      upload_photo!(live, user)

      assert has_element?(live, ~s([phx-click="photo-move"]))
    end

    test "the editor shows a photo in its own aspect ratio, not a square crop", %{
      conn: conn,
      user: user
    } do
      # A photographer judges the upload by the full frame; the square crop
      # belongs to the compact text-mode strip alone. The test JPEG is 90×60.
      # The frame's shape alone is not enough: the `thumb` version is itself a
      # 320×320 centre crop (`Vutuv.Uploads.Spec`), so a natural-ratio frame
      # around it still shows a cut — the tile must load the aspect-preserving
      # `feed` version.
      live = open_photo_composer(conn)
      image = upload_photo!(live, user)

      assert has_element?(
               live,
               ~s([data-photo-tile="#{image.id}"] [style*="aspect-ratio: 90 / 60"])
             )

      assert has_element?(live, ~s([data-photo-tile="#{image.id}"] img[src$="/feed.avif"]))
    end

    test "the text-mode strip keeps its square thumbs", %{conn: conn, user: user} do
      live = open_composer(conn)
      image = upload_photo!(live, user)

      assert has_element?(live, ~s([data-photo-tile="#{image.id}"] img[src$="/thumb.avif"]))
    end

    test "the alt nudge shows only while a photo has neither caption nor description", %{
      conn: conn,
      user: user
    } do
      live = open_photo_composer(conn)
      image = upload_photo!(live, user)

      assert has_element?(live, ~s([data-photo-alt-missing="#{image.id}"]))

      # A caption gives the photo its accessible name (photo_alt/1 falls back
      # to it), so the nudge is satisfied without the panel.
      live
      |> form("#composer-form", %{
        "post" => %{"mode" => "photos"},
        "photo" => %{image.id => %{"caption" => "Zugfenster"}}
      })
      |> render_change()

      refute has_element?(live, ~s([data-photo-alt-missing="#{image.id}"]))
    end

    test "the licence stays with the photos in photo mode", %{conn: conn, user: user} do
      live = open_photo_composer(conn)
      upload_photo!(live, user)

      assert has_element?(live, "#composer-license")
    end

    test "the text editor unfolds on request and photo mode keeps a typed body", %{
      conn: conn,
      user: user
    } do
      live = open_photo_composer(conn)
      upload_photo!(live, user)

      live |> element("#composer-add-text") |> render_click()

      assert has_element?(live, ~s(#composer-form textarea[name="post[body]"]))
      refute has_element?(live, "#composer-add-text")

      # Switching to text mode and back never drops the body or the photos.
      live
      |> form("#composer-form", %{"post" => %{"mode" => "text", "body" => "Ein Satz dazu."}})
      |> render_change()

      assert has_element?(live, ~s(#composer[data-composer-mode="text"]))

      live
      |> form("#composer-form", %{"post" => %{"mode" => "photos", "body" => "Ein Satz dazu."}})
      |> render_change()

      assert has_element?(live, ~s(#composer[data-composer-mode="photos"]))
      assert has_element?(live, "[data-photo-tile]")
      # A body exists, so the editor stays unfolded rather than hiding it.
      assert has_element?(live, ~s(#composer-form textarea[name="post[body]"]))
    end

    test "the unfolded editor stays open when the author deletes their text", %{
      conn: conn,
      user: user
    } do
      live = open_photo_composer(conn)
      upload_photo!(live, user)

      live |> element("#composer-add-text") |> render_click()

      live
      |> form("#composer-form", %{"post" => %{"mode" => "photos", "body" => "Erst was, dann"}})
      |> render_change()

      # Deleting the last character must not fold the editor away under the
      # cursor.
      live
      |> form("#composer-form", %{"post" => %{"mode" => "photos", "body" => ""}})
      |> render_change()

      assert has_element?(live, ~s(#composer-form textarea[name="post[body]"]))
      refute has_element?(live, "#composer-add-text")
    end

    test "after posting, the plain pill opens text-first again", %{conn: conn, user: user} do
      live = open_photo_composer(conn)
      upload_photo!(live, user)

      live |> form("#composer-form", %{"post" => %{"mode" => "photos"}}) |> render_submit()
      live |> element("#open-composer") |> render_click()

      assert has_element?(live, ~s(#composer[data-composer-mode="text"]))
    end

    test "the photo ✕ discards everything: rows deleted, form empty, panel collapsed", %{
      conn: conn,
      user: user
    } do
      live = open_photo_composer(conn)
      image = upload_photo!(live, user)

      live
      |> form("#composer-form", %{
        "post" => %{"mode" => "photos"},
        "photo" => %{image.id => %{"caption" => "Gleich weg"}}
      })
      |> render_change()

      live |> element(~s(button[phx-click="discard-draft"])) |> render_click()

      # The pending row (and with it the stored files) is gone, the panel is
      # collapsed, and reopening starts fresh and text-first.
      assert reload(image) == nil
      assert has_element?(live, "#composer-panel.hidden")

      live |> element("#open-composer") |> render_click()

      assert has_element?(live, ~s(#composer[data-composer-mode="text"]))
      refute has_element?(live, "[data-photo-tile]")
    end

    test "the text ✕ keeps the draft (issue #1135), only photo mode discards", %{
      conn: conn,
      user: _user
    } do
      live = open_composer(conn)

      live
      |> form("#composer-form", %{"post" => %{"mode" => "text", "body" => "Halb getippt."}})
      |> render_change()

      live |> element(~s(button[phx-click="close-composer"])) |> render_click()
      live |> element("#open-composer") |> render_click()

      assert render(live) =~ "Halb getippt."
    end

    test "photo mode explains itself in one line", %{conn: conn, user: _user} do
      live = open_photo_composer(conn)

      assert has_element?(live, "[data-photo-mode-hint]")

      live |> form("#composer-form", %{"post" => %{"mode" => "text"}}) |> render_change()

      refute has_element?(live, "[data-photo-mode-hint]")
    end

    test "a photo-only post saves from photo mode", %{conn: conn, user: user} do
      live = open_photo_composer(conn)
      image = upload_photo!(live, user)

      # No body field at all: the editor is folded away, which is the point —
      # the form still submits (the caption input is in the photo grid, the
      # alt refinement in the opened panel).
      open_panel(live, image)

      live
      |> form("#composer-form", %{
        "post" => %{"mode" => "photos"},
        "photo" => %{image.id => %{"caption" => "Abendlicht", "alt" => "Ein Sonnenuntergang"}}
      })
      |> render_submit()

      post = only_post(user)
      assert post.body == ""
      assert [%{caption: "Abendlicht", alt: "Ein Sonnenuntergang"}] = post.images
    end
  end

  describe "which mode an existing post opens in" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "editing a photo-only post opens photo-first", %{conn: conn, user: user} do
      image = pending_image!(user)
      {:ok, post} = Posts.create_post(user, %{body: "", image_ids: [image.id]})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      assert has_element?(live, ~s(#composer[data-composer-mode="photos"]))
    end

    test "editing a text post with an attached photo opens text-first", %{
      conn: conn,
      user: user
    } do
      image = pending_image!(user)
      {:ok, post} = Posts.create_post(user, %{body: "Worte dazu.", image_ids: [image.id]})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      assert has_element?(live, ~s(#composer[data-composer-mode="text"]))
    end

    test "a reply composer offers no photo mode", %{conn: conn, user: _user} do
      author = insert(:user)
      {:ok, parent} = Posts.create_post(author, %{body: "Ein Beitrag."})

      {:ok, live, _html} = live(conn, ~p"/posts/#{parent.id}/reply")

      refute has_element?(live, "#composer-mode-photos")
    end
  end

  describe "the cover badge" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user, live: open_composer(conn)}
    end

    test "appears only once a second photo makes the order mean anything", %{
      live: live,
      user: user
    } do
      upload_photo!(live, user)

      refute has_element?(live, "[data-cover-badge]")

      upload_photo!(live, user)

      assert has_element?(live, "[data-cover-badge]")
    end
  end

  describe "photos surviving a reconnect (form recovery, issue #1130's photo half)" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "every attached photo rides the form as a hidden id", %{conn: conn, user: user} do
      live = open_composer(conn)
      image = upload_photo!(live, user)

      assert has_element?(live, ~s(input[name="post[image_ids][]"][value="#{image.id}"]))
    end

    test "a freshly mounted composer re-adopts its pending photos from the replayed form", %{
      conn: conn,
      user: user
    } do
      image = pending_image!(user)

      # The re-mounted composer starts empty — exactly what a reconnect leaves.
      live = open_composer(conn)
      refute has_element?(live, "[data-photo-tile]")

      # Form recovery replays the change event with the OLD DOM's values —
      # values the fresh render does not carry, which is why this goes through
      # the element (the `form/3` helper insists on rendered inputs).
      live
      |> element("#composer-form")
      |> render_change(%{"post" => %{"mode" => "photos", "image_ids" => [image.id]}})

      assert has_element?(live, ~s([data-photo-tile="#{image.id}"]))
      assert has_element?(live, ~s(#composer[data-composer-mode="photos"]))
    end

    test "a recovered photo draft re-opens the collapsed feed composer", %{
      conn: conn,
      user: user
    } do
      image = pending_image!(user)

      {:ok, live, _html} = live(conn, ~p"/feed")
      assert has_element?(live, "#composer-panel.hidden")

      live
      |> element("#composer-form")
      |> render_change(%{"post" => %{"image_ids" => [image.id]}})

      refute has_element?(live, "#composer-panel.hidden")
    end

    test "somebody else's pending photo is never adopted", %{conn: conn, user: _user} do
      other = insert(:user)
      foreign = pending_image!(other)

      live = open_composer(conn)

      live
      |> element("#composer-form")
      |> render_change(%{"post" => %{"image_ids" => [foreign.id]}})

      refute has_element?(live, "[data-photo-tile]")
    end

    test "a photo already attached to a post is never adopted", %{conn: conn, user: user} do
      image = pending_image!(user)
      {:ok, _post} = Posts.create_post(user, %{body: "Schon gepostet.", image_ids: [image.id]})

      live = open_composer(conn)

      live
      |> element("#composer-form")
      |> render_change(%{"post" => %{"image_ids" => [image.id]}})

      refute has_element?(live, "[data-photo-tile]")
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

  describe "the download choice" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "it sits beside the licence in both modes, not behind a photo", %{
      conn: conn,
      user: user
    } do
      # Tapping a photo to find out whether the original can be downloaded is
      # exactly the hunt the photo grid was meant to end, so the question is
      # asked where the licence is asked.
      live = open_photo_composer(conn)
      upload_photo!(live, user)

      assert has_element?(live, "#composer-download")

      live |> form("#composer-form", %{"post" => %{"mode" => "text"}}) |> render_change()

      assert has_element?(live, "#composer-download")
    end

    test "no photos, no question", %{conn: conn} do
      live = open_composer(conn)

      refute has_element?(live, "#composer-download")
    end

    test "the web versions are all a visitor gets until the author says otherwise", %{
      conn: conn,
      user: user
    } do
      live = open_photo_composer(conn)
      image = upload_photo!(live, user)

      assert has_element?(live, ~s(#composer-download option[value="none"][selected]))

      live |> form("#composer-form", %{"post" => %{"mode" => "photos"}}) |> render_submit()

      assert %{download_original: false, download_exact: false} = reload(image)
    end

    test "offering the original answers for the whole set at once", %{conn: conn, user: user} do
      live = open_photo_composer(conn)
      first = upload_photo!(live, user)
      second = upload_photo!(live, user)

      choose_download(live, "clean")
      live |> form("#composer-form", %{"post" => %{"mode" => "photos"}}) |> render_submit()

      assert %{download_original: true, download_exact: false} = reload(first)
      assert %{download_original: true, download_exact: false} = reload(second)
    end

    test "the exact file is its own answer", %{conn: conn, user: user} do
      live = open_photo_composer(conn)
      image = upload_photo!(live, user)

      choose_download(live, "exact")
      live |> form("#composer-form", %{"post" => %{"mode" => "photos"}}) |> render_submit()

      assert %{download_original: true, download_exact: true} = reload(image)
    end

    test "a location is called out at the moment the exact file is picked", %{
      conn: conn,
      user: user
    } do
      live = open_photo_composer(conn)
      image = upload_photo!(live, user, exif: [{"exif-ifd3-GPSLatitude", "50/1 56/1 0/1"}])
      assert image.has_gps

      choose_download(live, "clean")
      refute has_element?(live, "[data-download-gps-warning]")

      choose_download(live, "exact")
      assert has_element?(live, "[data-download-gps-warning]")

      choose_download(live, "none")
      refute has_element?(live, "[data-download-gps-warning]")
    end

    test "a set without a location never warns", %{conn: conn, user: user} do
      live = open_photo_composer(conn)
      upload_photo!(live, user)

      choose_download(live, "exact")

      refute has_element?(live, "[data-download-gps-warning]")
    end

    test "a per-photo override reads as such, and no keystroke quietly undoes it", %{
      conn: conn,
      user: user
    } do
      live = open_photo_composer(conn)
      first = upload_photo!(live, user)
      second = upload_photo!(live, user)

      open_panel(live, first)
      toggle(live, first, "download_original")

      # The set now disagrees, and the select says so rather than claiming an
      # answer nobody gave.
      assert has_element?(live, ~s(#composer-download option[value="mixed"][selected]))

      # A validate carrying the select's stale value (every keystroke does)
      # must not push that value back onto the photos.
      live
      |> element("#composer-form")
      |> render_change(%{"post" => %{"mode" => "photos", "download" => "none"}})

      live |> form("#composer-form", %{"post" => %{"mode" => "photos"}}) |> render_submit()

      assert %{download_original: true} = reload(first)
      assert %{download_original: false} = reload(second)
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
