defmodule VutuvWeb.FeedPhotoZoomTest do
  @moduledoc """
  The magnifier on a photo in a preview card (feed, profile).

  A photo there is bounded by the card and its own tap opens the post, which is
  right and is exactly why the enlargement cannot be the same tap — the same
  reasoning the link capture's magnifier already carries. So the corner is a
  control of its own, and the three preview layouts (the floated squarish photo,
  the lone photo, the bento mosaic) each get one.

  The permalink deliberately gets none: there the photo's own tap already opens
  the lightbox, so a second control would offer the overlay the same picture
  twice as "next photo".
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Posts

  defp author, do: insert(:activated_user)

  defp photo_post(user, shapes) do
    images =
      for {w, h} <- shapes do
        insert(:post_image, user: user, width: w, height: h)
      end

    {:ok, post} =
      Posts.create_post(user, %{
        body: "A morning in Lisbon",
        image_ids: Enum.map(images, & &1.id)
      })

    post
  end

  defp profile_html(conn, user), do: html_response(get(conn, ~p"/#{user.username}"), 200)

  describe "the lone photo on a preview card" do
    test "carries a magnifier beside the link to the post, not inside it", %{conn: conn} do
      user = author()
      post = photo_post(user, [{1600, 1000}])

      html = profile_html(conn, user)

      # The picture's own tap still goes to the post — that is the whole reason
      # the enlargement needs a control of its own.
      assert [link] = elements(html, "[data-lightbox-gallery] a[href=\"#{Posts.path(post)}\"]")
      assert attribute(link, "class") =~ "block"

      # ... and the magnifier sits outside that anchor: a control nested in a
      # link is invalid markup and a second target for the same press.
      assert [] = elements(html, "a [data-lightbox-photo]")
      assert [corner] = elements(html, "[data-lightbox-photo][role=button]")
      assert attribute(corner, "class") =~ "hover-reveal"

      # The server names the file the overlay opens, the way the capture's
      # corner does — `PostImage.lightbox_url/1`, not the feed version the card
      # is already showing.
      assert attribute(corner, "data-photo-src") =~ "/xl."
    end

    test "the corner describes the photo, so the overlay reads the page", %{conn: conn} do
      user = author()
      image = insert(:post_image, user: user, width: 1600, height: 1000, caption: "Alfama")

      {:ok, _post} =
        Posts.create_post(user, %{
          body: "A morning in Lisbon",
          image_ids: [image.id],
          license: "cc-by-4.0"
        })

      html = profile_html(conn, user)

      assert [corner] = elements(html, "[data-lightbox-photo][role=button]")
      assert attribute(corner, "data-photo-caption") == "Alfama"
      assert attribute(corner, "data-photo-license") != ""
    end

    test "only the pointer sees it at rest, so a timeline of photos stays calm",
         %{conn: conn} do
      user = author()
      photo_post(user, [{1600, 1000}])

      html = profile_html(conn, user)

      assert [host] = elements(html, "[data-lightbox-gallery] > .hover-reveal-host")
      assert attribute(host, "class") =~ "relative"
    end

    test "a whole photo's corner is positioned against the picture, not the column",
         %{conn: conn} do
      user = author()
      photo_post(user, [{1000, 1500}])

      html = profile_html(conn, user)

      # The box the corner is measured against shrinks to the picture — and it
      # is INSIDE the gallery, because the gallery is what the feed pulls out to
      # a phone's screen edges with negative margins, which would beat this
      # box's `mx-auto` and slide a portrait off the left edge.
      assert [gallery] = elements(html, "[data-lightbox-gallery][data-media-edge]")
      refute attribute(gallery, "class") =~ "w-fit"

      assert [host] = elements(html, "[data-media-edge] > .hover-reveal-host")
      assert attribute(host, "class") =~ "w-fit"
      assert attribute(host, "class") =~ "mx-auto"
    end
  end

  describe "the floated squarish photo" do
    test "keeps the float on the gallery, so the corner sits on the picture", %{conn: conn} do
      user = author()
      photo_post(user, [{1200, 1200}])

      html = profile_html(conn, user)

      assert [gallery] = elements(html, "[data-lightbox-gallery]")
      assert attribute(gallery, "class") =~ "float-right"
      assert attribute(gallery, "class") =~ "hover-reveal-host"
      assert [_] = elements(html, "[data-lightbox-photo][role=button]")
    end
  end

  describe "the bento mosaic" do
    test "one corner opens the set, and every tile describes its own photo", %{conn: conn} do
      user = author()
      post = photo_post(user, [{1600, 1000}, {1000, 1600}, {1200, 1200}])

      html = profile_html(conn, user)

      # A tile's own tap opens the post, as it always did.
      assert [_] = elements(html, "a[href=\"#{Posts.path(post)}\"][data-post-mosaic]")

      # One control, three photos: the tiles are the overlay's gallery, so the
      # arrows step through the set the card is showing.
      assert [corner] = elements(html, "[data-lightbox-photo][role=button]")
      assert attribute(corner, "data-photo-src") == ""
      assert [_, _, _] = elements(html, "[data-post-mosaic] [data-photo-src]")
    end
  end

  describe "the permalink" do
    test "has no corner: the photo's own tap already opens the overlay", %{conn: conn} do
      user = author()
      post = photo_post(user, [{1600, 1000}])

      html = html_response(get(conn, Posts.path(post)), 200)

      assert [] = elements(html, "[data-lightbox-photo][role=button]")
      assert [link] = elements(html, "a[data-lightbox-photo]")
      assert attribute(link, "class") =~ "cursor-zoom-in"
    end
  end

  describe "lightbox.js" do
    @js Path.expand("../../assets/js/lightbox.js", __DIR__)

    test "reads the gallery's photos off what describes one, not off what opens it" do
      js = File.read!(@js)

      assert js =~ ~s|querySelectorAll("[data-photo-src]")|,
             "a mosaic tile describes a photo and is not a control; the corner over it is a control and describes none"
    end

    test "a magnifier can be pressed from the keyboard" do
      js = File.read!(@js)

      assert js =~ ~s|[data-lightbox-photo][role=button]|,
             "a role=button span gets no click from Enter or Space, so it would be a tab stop that does nothing"
    end
  end
end
