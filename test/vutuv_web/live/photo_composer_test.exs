defmodule VutuvWeb.PhotoComposerTest do
  @moduledoc """
  The composer's photo handling (issue #1104), now as ONE composer with no
  Text/Fotos tabs: the editor is always on screen, attached photos always
  render as the large natural-ratio grid with their caption inline, and the
  two rights questions (licence, download) fold behind a collapsed "Photo
  details" row that appears with the first photo.

  Photos are put in through the **real upload path** — a crafted JPEG through
  `live_file_input` — rather than by inserting rows, because half of what is
  asserted here depends on what the upload parsed out of the file: whether
  there are camera settings to offer, and whether the photo carries a location
  worth warning about.

  The guiding claim of the feature is that everything beyond "drop photos and
  press Post" is one switch, so much of what is asserted is what does **not**
  appear: no panel until you ask for one, no licence select until the details
  row is opened, no exact-file choice until a download is offered.
  """

  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vix.Vips.MutableImage
  alias Vutuv.Posts
  alias Vutuv.Posts.GalleryLayout
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

  # The licence and download answers moved from a folded row into the gallery
  # sheet (issue #1892), which is also where the arrangement lives now — one
  # control for everything that belongs to the set rather than to one photo.
  defp open_details(live) do
    live |> element("#composer-gallery-open") |> render_click()
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
    |> element("#composer-gallery-download")
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

  describe "a post without photos" do
    test "shows no photo controls at all", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      live = open_composer(conn)

      refute render(live) =~ "data-photo-tile"
      # The two rights questions are about photos; without one they would be
      # controls about nothing.
      refute has_element?(live, "[data-gallery-open]")
      refute has_element?(live, "#composer-gallery-license")
      refute has_element?(live, "#composer-gallery-download")
    end
  end

  describe "one composer, no tabs" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "there is no Text/Fotos switch, and the editor is always on screen", %{conn: conn} do
      live = open_composer(conn)

      refute has_element?(live, ~s(input[name="post[mode]"]))
      assert has_element?(live, ~s(#composer-form textarea[name="post[body]"]))
    end

    test "photos are added from inside the composer", %{conn: conn} do
      # The feed's round camera button is gone (2026-08-31): it bought a second
      # control on the compose line for a gesture the composer already offers
      # one click further in, and the line's width is the teaser's.
      live = open_composer(conn)

      refute has_element?(live, "#open-photo-composer")
      assert has_element?(live, "#composer-add-photos")
    end

    test "a photo grows into the grid: natural ratio, feed version, caption inline", %{
      conn: conn,
      user: user
    } do
      live = open_composer(conn)
      image = upload_photo!(live, user)

      # The tile keeps the photo's own shape (the test JPEG is 90×60) and
      # loads the aspect-preserving `feed` version — `thumb` is itself a
      # 320×320 centre crop, so it would show a cut of a cut.
      assert has_element?(
               live,
               ~s([data-photo-tile="#{image.id}"] [style*="aspect-ratio: 90 / 60"])
             )

      assert has_element?(live, ~s([data-photo-tile="#{image.id}"] img[src$="/feed.avif"]))

      # The caption is one tap in, in the photo's own sheet — it used to sit
      # inline under the tile, which is what made one photo's settings live in
      # two places at once (issue #1892).
      refute has_element?(live, ~s(input[name="photo[#{image.id}][caption]"]))
      open_panel(live, image)
      assert has_element?(live, ~s(input[name="photo[#{image.id}][caption]"]))

      # Adding more photos sits in the row under the pictures, not as a tile
      # among them: the mosaic's cells are the arrangement, and a "+" occupying
      # one of them would be a seat the gallery does not have (issue #1892).
      # The id is unchanged, so the feed's camera button still finds its target.
      refute has_element?(live, "[data-photo-add-tile]")
      assert has_element?(live, "#composer-add-photos")
    end

    test "the alt text lives in the panel, and no second caption field appears", %{
      conn: conn,
      user: user
    } do
      live = open_composer(conn)
      image = upload_photo!(live, user)

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

    test "a photo carrying camera facts offers the publish switch in its sheet", %{
      conn: conn,
      user: user
    } do
      live = open_composer(conn)

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

      # In the photo's sheet, beside its caption and description — the switch
      # is about this picture, so it lives where everything about this picture
      # lives (issue #1892).
      refute has_element?(live, ~s([data-photo-camera-inline="#{image.id}"]))
      open_panel(live, image)

      assert has_element?(live, ~s([data-photo-camera-inline="#{image.id}"]))
      assert render(live) =~ "Canon EOS R6 · 50 mm · f/1.8 · 1/200 s · ISO 400"

      live
      |> element(~s([data-photo-camera-inline="#{image.id}"] input[phx-click="photo-toggle"]))
      |> render_click()

      live |> form("#composer-form") |> render_submit()

      assert %{show_camera_info: true} = reload(image)
    end

    test "a photo without camera facts gets no camera row", %{conn: conn, user: user} do
      live = open_composer(conn)
      image = upload_photo!(live, user)

      refute has_element?(live, ~s([data-photo-camera-inline="#{image.id}"]))
    end

    test "tiles reorder by pointer drag alone — no arrow dots on any count", %{
      conn: conn,
      user: user
    } do
      live = open_composer(conn)
      image = upload_photo!(live, user)

      # The frame is the drag zone (the PhotoStrip hook's contract) and the
      # tile keeps its remove dot; the old ◀ ▶ arrow pair is gone for good.
      assert has_element?(live, ~s([data-photo-drag="#{image.id}"]))
      assert has_element?(live, ~s(button[phx-click="remove-image"][phx-value-id="#{image.id}"]))
      refute has_element?(live, ~s([phx-click="photo-move"]))

      upload_photo!(live, user)
      refute has_element?(live, ~s([phx-click="photo-move"]))
    end

    test "the alt nudge shows only while a photo has neither caption nor description", %{
      conn: conn,
      user: user
    } do
      live = open_composer(conn)
      image = upload_photo!(live, user)

      assert has_element?(live, ~s([data-photo-alt-missing="#{image.id}"]))

      # A caption gives the photo its accessible name (photo_alt/1 falls back
      # to it), so the nudge is satisfied by either field — which is the point
      # of writing them side by side in the photo's own sheet.
      open_panel(live, image)

      live
      |> form("#composer-form", %{
        "photo" => %{image.id => %{"caption" => "Zugfenster"}}
      })
      |> render_change()

      refute has_element?(live, ~s([data-photo-alt-missing="#{image.id}"]))
    end

    test "a photo-only post saves with an empty body", %{conn: conn, user: user} do
      live = open_composer(conn)
      image = upload_photo!(live, user)

      open_panel(live, image)

      live
      |> form("#composer-form", %{
        "photo" => %{image.id => %{"caption" => "Abendlicht", "alt" => "Ein Sonnenuntergang"}}
      })
      |> render_submit()

      post = only_post(user)
      assert post.body == ""
      assert [%{caption: "Abendlicht", alt: "Ein Sonnenuntergang"}] = post.images
    end

    test "the ✕ closes the composer and keeps the draft, photos included", %{
      conn: conn,
      user: user
    } do
      live = open_composer(conn)
      image = upload_photo!(live, user)

      live |> element(~s(#composer-form button[phx-click="close-composer"])) |> render_click()

      # Collapsed, not discarded: the pending row survives, and reopening
      # shows the photo right where it was left.
      assert has_element?(live, "#composer-panel.hidden")
      assert reload(image)

      live |> element("#open-composer") |> render_click()

      assert has_element?(live, ~s([data-photo-tile="#{image.id}"]))
    end

    test "Discard draft really discards: rows deleted, form empty, panel collapsed", %{
      conn: conn,
      user: user
    } do
      live = open_composer(conn)
      image = upload_photo!(live, user)

      # The caption field only exists while the photo's sheet is open.
      open_panel(live, image)

      live
      |> form("#composer-form", %{
        "photo" => %{image.id => %{"caption" => "Gleich weg"}}
      })
      |> render_change()

      live |> element("#composer-discard") |> render_click()

      assert reload(image) == nil
      assert has_element?(live, "#composer-panel.hidden")

      live |> element("#open-composer") |> render_click()

      refute has_element?(live, "[data-photo-tile]")
    end

    test "the discard control shows only while there is something to lose", %{conn: conn} do
      live = open_composer(conn)

      refute has_element?(live, "#composer-discard")

      live
      |> form("#composer-form", %{"post" => %{"body" => "Ein halber Gedanke"}})
      |> render_change()

      assert has_element?(live, "#composer-discard")
    end

    test "editing a photo-only post shows the grid and the folded details row", %{
      conn: conn,
      user: user
    } do
      image = pending_image!(user)
      {:ok, post} = Posts.create_post(user, %{body: "", image_ids: [image.id]})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      assert has_element?(live, ~s([data-photo-tile="#{image.id}"]))
      assert has_element?(live, "#composer-gallery-open")
      assert has_element?(live, ~s(#composer-form textarea[name="post[body]"]))
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

    test "one photo gets no download switch: the post-wide select is its answer", %{
      live: live,
      user: user
    } do
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
      live |> form("#composer-form") |> render_submit()

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
      |> render_change(%{"post" => %{"image_ids" => [image.id]}})

      assert has_element?(live, ~s([data-photo-tile="#{image.id}"]))
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

  describe "the photo details row (licence & download)" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "folded until asked, and only there once a photo is attached", %{
      conn: conn,
      user: user
    } do
      live = open_composer(conn)

      refute has_element?(live, "#composer-gallery-open")

      upload_photo!(live, user)

      # The row is there, its answers are named on the fold, but the selects
      # stay away until the author opens it.
      assert has_element?(live, "#composer-gallery-open")
      assert render(live) =~ "All rights reserved"
      refute has_element?(live, "#composer-gallery-license")
      refute has_element?(live, "#composer-gallery-download")

      open_details(live)

      assert has_element?(live, "#composer-gallery-license")
      assert has_element?(live, "#composer-gallery-download")
    end

    test "left untouched, a post keeps the defaults silently", %{conn: conn, user: user} do
      # Stapling a screenshot to a text does not make somebody a publisher of
      # pictures: nobody is forced to rule on reuse rights or original files
      # as the price of an ordinary post.
      live = open_composer(conn)
      upload_photo!(live, user)

      live
      |> form("#composer-form", %{"post" => %{"body" => "Ein Screenshot."}})
      |> render_submit()

      post = only_post(user)
      assert post.license == "arr"
      assert [%{download_original: false, download_exact: false}] = post.images
    end

    test "the licence is remembered for next time", %{conn: conn, user: user} do
      live = open_composer(conn)
      upload_photo!(live, user)
      open_details(live)

      live
      |> form("#composer-form", %{"post" => %{"license" => "cc-by-4.0"}})
      |> render_submit()

      post = only_post(user)
      assert post.license == "cc-by-4.0"
      assert Vutuv.Accounts.User |> Repo.get(user.id) |> Posts.default_license() == "cc-by-4.0"
    end

    test "an edit that never opens the details keeps the stored answers", %{
      conn: conn,
      user: user
    } do
      # The selects render only once the row is opened, so a save without them
      # must fall back to what is stored rather than resetting it.
      image = pending_image!(user)

      {:ok, post} =
        Posts.create_post(user, %{
          body: "Worte dazu.",
          image_ids: [image.id],
          license: "cc-by-sa-4.0"
        })

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      assert has_element?(live, "#composer-gallery-open")
      refute has_element?(live, "#composer-gallery-license")

      live |> form("#composer-form", %{"post" => %{"body" => "Andere Worte."}}) |> render_submit()

      assert %{body: "Andere Worte.", license: "cc-by-sa-4.0"} = Repo.get!(Post, post.id)
    end

    test "the web versions are all a visitor gets until the author says otherwise", %{
      conn: conn,
      user: user
    } do
      live = open_composer(conn)
      image = upload_photo!(live, user)
      open_details(live)

      assert has_element?(live, ~s(#composer-gallery-download option[value="none"][selected]))

      live |> form("#composer-form") |> render_submit()

      assert %{download_original: false, download_exact: false} = reload(image)
    end

    test "offering the original answers for the whole set at once", %{conn: conn, user: user} do
      live = open_composer(conn)
      first = upload_photo!(live, user)
      second = upload_photo!(live, user)
      open_details(live)

      choose_download(live, "clean")
      live |> form("#composer-form") |> render_submit()

      assert %{download_original: true, download_exact: false} = reload(first)
      assert %{download_original: true, download_exact: false} = reload(second)
    end

    test "the exact file is its own answer", %{conn: conn, user: user} do
      live = open_composer(conn)
      image = upload_photo!(live, user)
      open_details(live)

      choose_download(live, "exact")
      live |> form("#composer-form") |> render_submit()

      assert %{download_original: true, download_exact: true} = reload(image)
    end

    test "a location is called out at the moment the exact file is picked", %{
      conn: conn,
      user: user
    } do
      live = open_composer(conn)
      image = upload_photo!(live, user, exif: [{"exif-ifd3-GPSLatitude", "50/1 56/1 0/1"}])
      assert image.has_gps
      open_details(live)

      choose_download(live, "clean")
      refute has_element?(live, "[data-download-gps-warning]")

      choose_download(live, "exact")
      assert has_element?(live, "[data-download-gps-warning]")

      choose_download(live, "none")
      refute has_element?(live, "[data-download-gps-warning]")
    end

    test "a set without a location never warns", %{conn: conn, user: user} do
      live = open_composer(conn)
      upload_photo!(live, user)
      open_details(live)

      choose_download(live, "exact")

      refute has_element?(live, "[data-download-gps-warning]")
    end

    test "a per-photo override reads as such, and no keystroke quietly undoes it", %{
      conn: conn,
      user: user
    } do
      live = open_composer(conn)
      first = upload_photo!(live, user)
      second = upload_photo!(live, user)
      open_details(live)

      open_panel(live, first)
      toggle(live, first, "download_original")

      # The set now disagrees, and the select says so rather than claiming an
      # answer nobody gave.
      assert has_element?(live, ~s(#composer-gallery-download option[value="mixed"][selected]))

      # A validate carrying the select's stale value (every keystroke does)
      # must not push that value back onto the photos.
      live
      |> element("#composer-form")
      |> render_change(%{"post" => %{"download" => "none"}})

      live |> form("#composer-form") |> render_submit()

      assert %{download_original: true} = reload(first)
      assert %{download_original: false} = reload(second)
    end
  end

  describe "reordering" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user, live: open_composer(conn)}
    end

    test "a dragged order is what saves, and the first photo leads the mosaic", %{
      live: live,
      user: user
    } do
      first = upload_photo!(live, user)
      second = upload_photo!(live, user)

      # The PhotoStrip hook's push after a pointer drop: the DOM order it
      # already applied, as ids.
      live
      |> element("#composer-images")
      |> render_hook("photo-reorder", %{"order" => [second.id, first.id]})

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

  describe "the gallery sheet" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, live: open_composer(conn), user: user}
    end

    test "the tiles ARE the mosaic; the sheet holds what belongs to the set", %{
      live: live,
      user: user
    } do
      upload_photo!(live, user)
      # One photo is no arrangement, so the control names the two rights
      # questions instead — they are the whole of what the sheet then holds,
      # and they have to stay reachable for a single photo.
      assert has_element?(live, "[data-gallery-open]")
      assert render(live) =~ "Photo details"
      refute render(live) =~ "grid-template-columns: repeat(12, 1fr)"

      upload_photo!(live, user)

      # The tiles themselves are laid out on the mosaic's 12x6 grid — there is
      # no separate preview to compare them against any more (issue #1892).
      assert render(live) =~ "grid-template-columns: repeat(12, 1fr)"
      refute has_element?(live, "[data-bento-preview]")
      refute has_element?(live, "[data-bento-editor]")

      # The set's choices are one control away, and the chip names what is in
      # force so the arrangement reads without opening it.
      assert has_element?(live, "[data-gallery-open]")
      refute has_element?(live, "[data-gallery-sheet]")

      live |> element("[data-gallery-open]") |> render_click()
      assert has_element?(live, "[data-gallery-sheet]")
      assert has_element?(live, ~s([data-bento-pattern="auto"][aria-pressed="true"]))

      for variant <- GalleryLayout.variants(2) do
        assert has_element?(live, ~s([data-bento-pattern="#{variant.name}"]))
      end
    end

    test "dragging one photo onto another swaps them, and that order saves", %{
      live: live,
      user: user
    } do
      first = upload_photo!(live, user)
      second = upload_photo!(live, user)

      # The drop the PhotoStrip hook reports. It names both ends in one event —
      # the tap-tap swap it replaces needed a "which one is marked" mode, and a
      # preview to tap in.
      live
      |> element("#composer-images")
      |> render_hook("photo-swap", %{"from" => first.id, "to" => second.id})

      live |> form("#composer-form", %{"post" => %{"body" => "Swapped."}}) |> render_submit()
      post = only_post(user)

      assert Enum.map(post.images, & &1.id) == [second.id, first.id]
    end

    test "a swap onto itself, or onto a photo that is gone, changes nothing", %{
      live: live,
      user: user
    } do
      first = upload_photo!(live, user)
      second = upload_photo!(live, user)

      for params <- [
            %{"from" => first.id, "to" => first.id},
            %{"from" => first.id, "to" => "not-a-real-id"},
            %{"from" => "gone", "to" => second.id}
          ] do
        live |> element("#composer-images") |> render_hook("photo-swap", params)
      end

      live |> form("#composer-form", %{"post" => %{"body" => "Unmoved."}}) |> render_submit()
      post = only_post(user)

      assert Enum.map(post.images, & &1.id) == [first.id, second.id]
    end

    test "a pattern chip sets the arrangement and the save stores it", %{
      live: live,
      user: user
    } do
      upload_photo!(live, user)
      upload_photo!(live, user)
      live |> element("[data-gallery-open]") |> render_click()

      live |> element(~s([data-bento-pattern="stack"])) |> render_click()
      assert has_element?(live, ~s([data-bento-pattern="stack"][aria-pressed="true"]))
      refute has_element?(live, ~s([data-bento-pattern="auto"][aria-pressed="true"]))

      live |> form("#composer-form", %{"post" => %{"body" => "Stacked."}}) |> render_submit()
      assert only_post(user).gallery_layout == "stack"
    end

    test "whole photos are the default fit; filling the tiles is the explicit choice", %{
      live: live,
      user: user
    } do
      upload_photo!(live, user)
      upload_photo!(live, user)
      live |> element("[data-gallery-open]") |> render_click()

      assert has_element?(live, ~s([data-bento-fit="whole"][aria-pressed="true"]))
      assert has_element?(live, ~s([data-bento-fit="fill"][aria-pressed="false"]))
      # The fit is read off the TILES now, because the tiles are the gallery.
      assert has_element?(live, "#composer-images img.object-contain")

      live |> element(~s([data-bento-fit="fill"])) |> render_click()
      assert has_element?(live, ~s([data-bento-fit="fill"][aria-pressed="true"]))
      assert has_element?(live, "#composer-images img.object-cover")
    end

    test "the arrangement and the fit survive a reconnect", %{
      conn: conn,
      live: live,
      user: user
    } do
      upload_photo!(live, user)
      upload_photo!(live, user)
      live |> element("[data-gallery-open]") |> render_click()

      live |> element(~s([data-bento-fit="fill"])) |> render_click()
      live |> element(~s([data-bento-pattern="stack"])) |> render_click()

      reopened = open_composer(conn)
      # The sheet itself is a view, not data: it comes back closed, and what it
      # was showing is still in force underneath.
      refute has_element?(reopened, "[data-gallery-sheet]")

      reopened |> element("[data-gallery-open]") |> render_click()
      assert has_element?(reopened, ~s([data-bento-fit="fill"][aria-pressed="true"]))
      assert has_element?(reopened, ~s([data-bento-pattern="stack"][aria-pressed="true"]))
    end

    test "a photo past the mosaic's five tiles stays reachable", %{live: live, user: user} do
      images = for _ <- 1..6, do: upload_photo!(live, user)
      sixth = List.last(images)

      # The post shows five; the composer holds ten. Hiding the sixth behind a
      # "+1" the author cannot open would make it impossible to remove.
      assert has_element?(live, ~s(#composer-overflow [data-photo-tile="#{sixth.id}"]))

      live
      |> element(
        ~s(#composer-overflow [data-photo-tile="#{sixth.id}"] [phx-click="remove-image"])
      )
      |> render_click()

      refute has_element?(live, ~s([data-photo-tile="#{sixth.id}"]))
    end
  end

  describe "the ratio crop" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{live: open_composer(conn), user: user}
    end

    test "the crop verdict re-derives the photo and marks the tile", %{live: live, user: user} do
      image = upload_photo!(live, user)
      refute render(live) =~ "data-photo-cropped"

      live
      |> element("#composer-images")
      |> render_hook("photo-crop", %{"id" => image.id, "crop" => "0,0,0.5,0.5"})

      cropped = reload(image)
      assert cropped.crop == "0.0000,0.0000,0.5000,0.5000"
      # The fixture is 90×60, so the half-crop serves 45×30.
      assert {cropped.width, cropped.height} == {45, 30}

      html = render(live)
      # The tile now shows the cropped picture (crop-keyed cache buster)…
      assert html =~ "feed.avif?v="
      # …and says a crop is in force.
      assert has_element?(live, ~s([data-photo-cropped="#{image.id}"]))
    end

    test "an empty crop resets to the whole photo", %{live: live, user: user} do
      image = upload_photo!(live, user)

      live
      |> element("#composer-images")
      |> render_hook("photo-crop", %{"id" => image.id, "crop" => "0,0,0.5,0.5"})

      live
      |> element("#composer-images")
      |> render_hook("photo-crop", %{"id" => image.id, "crop" => ""})

      reset = reload(image)
      assert reset.crop == nil
      assert {reset.width, reset.height} == {90, 60}
      refute render(live) =~ "data-photo-cropped"
    end

    test "another member's photo cannot be cropped through this composer", %{
      live: live,
      user: user
    } do
      _own = upload_photo!(live, user)
      other = insert(:user, email_confirmed?: true)
      foreign = pending_image!(other)

      live
      |> element("#composer-images")
      |> render_hook("photo-crop", %{"id" => foreign.id, "crop" => "0,0,0.5,0.5"})

      assert reload(foreign).crop == nil
    end

    test "the exact-file choice is disabled and explained once cropped", %{
      live: live,
      user: user
    } do
      image = upload_photo!(live, user)
      _second = upload_photo!(live, user)

      live
      |> element("#composer-images")
      |> render_hook("photo-crop", %{"id" => image.id, "crop" => "0,0,0.5,0.5"})

      open_panel(live, image)
      toggle(live, image, "download_original")

      assert has_element?(
               live,
               ~s(input[phx-value-id="#{image.id}"][phx-value-exact="true"][disabled])
             )

      assert has_element?(live, "[data-photo-crop-download-note]")
    end

    test "each tile offers the crop dot wired to the author-only workbench", %{
      live: live,
      user: user
    } do
      image = upload_photo!(live, user)

      assert has_element?(
               live,
               ~s([data-photo-crop="#{image.id}"][data-crop-src="/post_images/#{image.token}/source.avif"])
             )
    end
  end

  describe "drop anywhere" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{live: open_composer(conn), user: user}
    end

    test "the whole form is the drop zone, from the first drag on", %{live: live} do
      # The zone and its overlay exist before any photo is attached.
      assert has_element?(live, "#composer-form[data-composer-dropzone][phx-drop-target]")
      assert has_element?(live, "#composer-form [data-drop-overlay]")
    end

    test "the photo grid carries no drop target of its own", %{live: live, user: user} do
      upload_photo!(live, user)

      # A nested second zone would steal the active state from the overlay.
      refute has_element?(live, "#composer-images[phx-drop-target]")
    end
  end

  # The German render, asserted by name: short labels like "Auto" are exactly
  # what `gettext.extract --merge` fuzzy-fills with a neighbour's translation
  # ("Autor(en)"), and nothing else fails the build on that.
  describe "the German copy" do
    test "the workshop's labels render in German", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # The login helper has already sent a response; recycle keeps the
      # session cookies and lets the next request carry the German header.
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")
      live = open_composer(conn)

      upload_photo!(live, user)
      upload_photo!(live, user)

      # What the tiles themselves say, before anything is opened.
      html = render(live)
      assert html =~ "Galerie"
      assert html =~ "Ein Foto auf ein anderes ziehen, um sie zu tauschen."
      assert html =~ "Foto zuschneiden"
      assert html =~ "Fotos hier ablegen, um sie hinzuzufügen"

      # …and what the sheet says once it is.
      html = open_details(live)
      assert html =~ "Automatisch"
      assert html =~ "Nebeneinander"
      assert html =~ "Ganze Fotos"
      assert html =~ "Kacheln füllen"
      assert html =~ "Lizenz"
    end
  end
end
