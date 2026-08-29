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

  # No file and nothing left to wait for. Two ways in, because the two answers
  # come from different places: the gate refused the bytes, or the download used
  # up its tries. Both mean the same thing to a reader.
  defp gone_picture(attrs \\ [moderation: "rejected"]),
    do: struct(%RemoteImage{file: nil, moderation: "pending"}, attrs)

  test "a picture that is not coming stops claiming a check is running" do
    html = render_tile([gone_picture()])

    assert html =~ "data-remote-image-unavailable"
    assert html =~ "Picture unavailable"
    # The old lie, on some production rows since 2026-08-03.
    refute html =~ "data-remote-image-pending"
    refute html =~ "Picture is being checked"
    # ...and no line under the grid promising the AI will be through shortly.
    refute html =~ "data-remote-images-checking"
  end

  test "a rejection written before the state existed reads the same" do
    # `apply_rejected/1` used to leave `moderation` null, which is how the four
    # oldest such rows on production are stored.
    assert render_tile([gone_picture(moderation: nil)]) =~ "data-remote-image-unavailable"
  end

  test "a download that used up its tries reads the same" do
    # The other half, and the one the verdict column knows nothing about: the
    # gate never saw this picture, the refetcher simply stopped asking.
    spent = gone_picture(fetch_failures: RemoteImage.max_fetch_failures())

    assert render_tile([spent]) =~ "data-remote-image-unavailable"
  end

  test "German says it too" do
    Gettext.put_locale(VutuvWeb.Gettext, "de")

    assert render_tile([gone_picture()]) =~ "Bild nicht verfügbar"
  end

  test "a picture still waiting is not confused with one that is gone" do
    html = render_tile([held_picture(), gone_picture()])

    assert html =~ "data-remote-image-pending"
    assert html =~ "data-remote-image-unavailable"
    # One of the two is really being checked, and the line counts only that one.
    assert html =~ ~s(data-remote-images-checking="1")
  end

  test "an author's covered picture still opens behind a click" do
    # Moved when the three-way `if` became one `case` over `display_state/1`,
    # and until then it had no test at all.
    covered = %RemoteImage{file: "img-abc.avif", moderation: "approved", sensitive: true}

    html = render_tile([covered])

    assert html =~ "data-remote-image-sensitive"
    assert html =~ "Sensitive. Show the picture."
  end

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
