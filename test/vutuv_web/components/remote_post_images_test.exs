defmodule VutuvWeb.RemotePostImagesTest do
  @moduledoc """
  What a cached post's picture says while it is still held back.

  The tile stands in for a picture that is recorded but not released: the file
  may still be coming from its own server, and the AI gate has not cleared it.
  It used to say "a picture is on its way", which named the one half of that
  wait the reader is not actually waiting for. The wording is asserted by name
  and in German, because a short string is exactly the kind a `gettext.extract
  --merge` fuzzy-fills with somebody else's translation.

  The line **under** the grid is asserted here too. A pixelated preview carries
  a corner badge, and two blocky tiles under a stranger's post with nothing but
  that read as a broken image rather than as a check in progress — reported on
  a fediverse card the day this shipped.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse.RemoteImage
  alias VutuvWeb.PostComponents

  # No file yet and the gate still open: `RemoteImage.released?/1` says no on
  # either count, which is the whole condition the tile stands for.
  defp held_picture, do: %RemoteImage{file: nil, moderation: "pending"}

  defp render_tile(images),
    do: render_component(&PostComponents.remote_post_images/1, images: images)

  test "a held picture says it is being checked, not that it is travelling" do
    html = render_tile([held_picture()])

    assert html =~ "data-remote-image-pending"
    assert html =~ "Picture is being checked"
    refute html =~ "on its way"
  end

  test "German says what a member's own held photo says" do
    Gettext.put_locale(VutuvWeb.Gettext, "de")

    assert render_tile([held_picture()]) =~ "Bild wird geprüft"
  end

  describe "the line under the grid" do
    test "says what the wait is, and counts the pictures it covers" do
      one = render_tile([held_picture()])
      assert one =~ ~s(data-remote-images-checking="1")
      assert one =~ "Our AI is looking at it."

      two = render_tile([held_picture(), held_picture()])
      assert two =~ ~s(data-remote-images-checking="2")
      assert two =~ "Our AI is looking at them."
    end

    test "stays away once every picture is released" do
      released = %RemoteImage{file: "img-abc.avif", moderation: "approved"}

      refute render_tile([released]) =~ "data-remote-images-checking"
    end

    test "is the same sentence a member's own held photo gets, in German" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")

      assert render_tile([held_picture()]) =~ "Unsere KI sieht es sich an."
    end
  end
end
