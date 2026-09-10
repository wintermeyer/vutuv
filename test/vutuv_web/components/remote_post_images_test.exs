defmodule VutuvWeb.RemotePostImagesTest do
  @moduledoc """
  What a cached post's picture says while it is still held back — and what it
  says once it is not coming at all, which is nothing.

  The tile stands in for a picture that is recorded but not released: the file
  may still be coming from its own server, and the AI gate has not cleared it.
  It used to say "a picture is on its way", which named the one half of that
  wait the reader is not actually waiting for. The wording is asserted by name
  and in German, because a short string is exactly the kind a `gettext.extract
  --merge` fuzzy-fills with somebody else's translation.

  A picture that is **not** coming leaves the grid entirely: no tile, no
  "Picture unavailable", and no grid at all where it was the only one. Both
  halves are asserted, because the state that must vanish and the state that
  must stay look identical in the data. There is no German twin of that
  assertion: the msgid is gone from the catalogs, so a reverted fix would print
  the English string and a `refute` on "Bild nicht verfügbar" could never go
  red.

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

  test "a picture that is not coming is not drawn at all" do
    html = render_tile([gone_picture()])

    # Not a grey tile saying so, and — it was the post's only picture — not
    # even the grid that would have held one.
    refute html =~ "data-remote-image-unavailable"
    refute html =~ "Picture unavailable"
    refute html =~ "data-remote-images"
    # The older lie, on some production rows since 2026-08-03.
    refute html =~ "data-remote-image-pending"
    refute html =~ "Picture is being checked"
  end

  test "a rejection written before the state existed reads the same" do
    # `apply_rejected/1` used to leave `moderation` null, which is how the four
    # oldest such rows on production are stored.
    refute render_tile([gone_picture(moderation: nil)]) =~ "data-remote-images"
  end

  test "a download that used up its tries reads the same" do
    # The other half, and the one the verdict column knows nothing about: the
    # gate never saw this picture, the refetcher simply stopped asking.
    spent = gone_picture(fetch_failures: RemoteImage.max_fetch_failures())

    refute render_tile([spent]) =~ "data-remote-images"
  end

  test "a picture still waiting is not confused with one that is gone" do
    html = render_tile([held_picture(), gone_picture()])

    assert html =~ "data-remote-image-pending"
    refute html =~ "data-remote-image-unavailable"
    # The grid holds the one picture there still is, so the pair does not lay
    # itself out as two columns with an empty one.
    assert html =~ ~s(data-remote-images="1")
    refute html =~ "grid-cols-2"
    # And that one is really being checked, so the line counts it.
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

  # A clip is the one attachment this installation does not hold: only its
  # cover is fetched and judged, the clip itself streams from the server that
  # published it. Two consequences the card has to carry.
  describe "a clip" do
    defp held_clip(attrs \\ []) do
      struct(
        %RemoteImage{
          id: Vutuv.UUIDv7.generate(),
          file: nil,
          moderation: "pending",
          media_type: "video/mp4",
          poster_uri: "https://social.example/media/cover.png",
          duration_ms: 73_200
        },
        attrs
      )
    end

    defp released_clip(attrs \\ []) do
      struct(
        %RemoteImage{
          id: Vutuv.UUIDv7.generate(),
          file: "cover-abc.avif",
          moderation: "approved",
          media_type: "video/mp4",
          poster_uri: "https://social.example/media/cover.png",
          source_uri: "https://social.example/media/clip.mp4",
          duration_ms: 73_200,
          byte_size: 94_407_457
        },
        attrs
      )
    end

    # While the cover is with the gate the card shows the cover, and until this
    # it showed it as a photograph: no play glyph, no length, nothing saying a
    # clip was waiting. A reader cannot tell a held picture from a held clip,
    # which is the one thing the tile is there to say.
    test "waiting for the gate, it still reads as a clip" do
      html = render_tile([held_clip()])

      assert html =~ "data-remote-clip-waiting"
      # 73.2 s rounds UP to 74, the rule `PostVideo.seconds/1` already sets for a
      # member's own clip — one second past what the publishing instance prints.
      assert html =~ "1:14"
      assert html =~ "Video is being checked"
      refute html =~ "Picture is being checked"
    end

    # `mix gettext.extract --merge` fuzzy-filled this msgid with the picture
    # tile's translation ("Bild wird geprüft") — the exact silent-nonsense
    # failure the project rule warns about, so the German is asserted by name.
    test "German names the clip, not a picture" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      html = render_tile([held_clip()])

      assert html =~ "Video wird geprüft"
      refute html =~ "Bild wird geprüft"
    end

    # The measurement this label exists for: 73 seconds of phone video off
    # social.bund.de is 94 MB, and the server serves it without range support,
    # so a tap on a train costs the whole file.
    test "released, the poster says how long and how big before anybody taps" do
      html = render_tile([released_clip()])

      assert html =~ "data-remote-video"
      # 73.2 s rounds UP to 74, the rule `PostVideo.seconds/1` already sets for a
      # member's own clip — one second past what the publishing instance prints.
      assert html =~ "1:14"
      assert html =~ "94 MB"
    end

    test "an unmeasured clip says its length and stays quiet about the size" do
      html = render_tile([released_clip(byte_size: nil)])

      # 73.2 s rounds UP to 74, the rule `PostVideo.seconds/1` already sets for a
      # member's own clip — one second past what the publishing instance prints.
      assert html =~ "1:14"
      refute html =~ "MB"
    end

    test "a clip whose attachment carried no length says neither" do
      html = render_tile([released_clip(duration_ms: nil, byte_size: nil)])

      assert html =~ "data-remote-video"
      refute html =~ "data-remote-clip-facts"
    end

    # The three quarters of clips that arrive with no cover (27 of 36 in one
    # day's cached posts) have nothing to reserve a shape with, so the card
    # would draw a 16:9 black box for a portrait phone clip. The attachment
    # states the clip's own shape even when it sends no cover.
    # The common case, and the one that drew a black box: no `icon` in the
    # attachment, so nothing was ever fetched and there is no cover to show.
    # The BlurHash the same attachment carries stands in — the publishing
    # server's own blurred version, which shows the clip's colours and nothing
    # identifiable.
    test "a clip with no cover wears its BlurHash as the poster" do
      coverless =
        released_clip(
          poster_uri: nil,
          file: nil,
          blurhash: "UKFrYAoN0hM{IVbIShRj9Gog%M%2-gj]N1%2"
        )

      html = render_tile([coverless])

      assert html =~ "data-remote-video"
      assert html =~ ~s(poster="data:image/png;base64,)
    end

    # A poster is not a verdict. A coverless clip passes no gate at all, so
    # nothing here may read as "we looked at this".
    test "a clip with neither cover nor BlurHash gets no poster, not a broken one" do
      bare = released_clip(poster_uri: nil, file: nil, blurhash: nil)
      html = render_tile([bare])

      assert html =~ "data-remote-video"
      refute html =~ "poster="
    end

    test "a released cover beats the BlurHash" do
      # Both available: the real thing was fetched and judged, so it wins.
      html = render_tile([released_clip(blurhash: "UKFrYAoN0hM{IVbIShRj9Gog%M%2-gj]N1%2")])

      assert html =~ "data-remote-video"
      refute html =~ "data:image/png;base64,"
    end

    test "the player reserves the clip's own shape, not the cover's" do
      # No cover named at all — nothing to fetch and nothing to judge, so it
      # plays as it is (`RemoteImage.display_state/1`). This is the common case.
      coverless =
        released_clip(poster_uri: nil, file: nil, video_width: 1080, video_height: 1920)

      html = render_tile([coverless])

      assert html =~ "data-remote-video"
      assert html =~ "aspect-ratio: 1080 / 1920"
    end
  end
end
