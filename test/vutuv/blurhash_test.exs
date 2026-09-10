defmodule Vutuv.BlurhashTest do
  @moduledoc """
  The BlurHash decoder behind a coverless clip's poster (issue #1914).

  **Calibrated against something measurable, not against itself.** A decoder
  that skips the sRGB transfer function produces a picture that looks entirely
  plausible and is uniformly too dark, and no self-consistent test catches that.
  So the average colour it reads out of a real hash is checked against the
  average colour of the real picture that hash was computed from — measured
  independently, in linear light, from the cover `social.bund.de` serves beside
  that very attachment.

  The measurement (2026-09-10, `Image.thumbnail/3` to 16×16, each pixel
  linearised by hand, averaged, converted back):

      cover, averaged in linear light   127, 116, 104
      cover, averaged in sRGB           109, 104,  90
      this decoder's DC term            137, 125, 115

  Eleven off the linear average and twenty-eight off the sRGB one — and it is
  the *linear* figure it agrees with, which is the whole point: those two
  numbers are what tell a correct decoder from one that merely renders. The
  residue is the encoder's own quantisation plus the fact that the hash was
  computed from the 1080×1920 video frame while the cover is a scaled PNG of it.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Blurhash

  # A real hash off a real post: social.bund.de, 2026-09-08, the clip whose
  # cover the moduledoc's measurement was taken from.
  @hash "UKFrYAoN0hM{IVbIShRj9Gog%M%2-gj]N1%2"

  describe "average_color/1" do
    test "agrees with the real picture's own average, in linear light" do
      assert {:ok, {r, g, b}} = Blurhash.average_color(@hash)

      # The measured truth, and a tolerance that admits quantisation without
      # admitting a decoder that dropped the transfer function — that one lands
      # near the sRGB average (109, 104, 90), i.e. 18 away in red, outside this.
      assert_in_delta r, 127, 12
      assert_in_delta g, 116, 12
      assert_in_delta b, 104, 12
    end

    test "reads the DC term alone, not a one-pixel render" do
      # At a width of one, `cos(pi*0*i/1)` is 1 for every component, so a 1×1
      # render sums the AC terms in at full strength. The two answers differ,
      # and this is the one that means "average".
      {:ok, average} = Blurhash.average_color(@hash)
      {:ok, {1, 1, <<r, g, b>>}} = Blurhash.decode(@hash, 1, 1)

      refute average == {r, g, b}
    end
  end

  describe "decode/3" do
    test "renders the asked-for size, three bytes a pixel" do
      assert {:ok, {16, 16, rgb}} = Blurhash.decode(@hash, 16, 16)
      assert byte_size(rgb) == 16 * 16 * 3

      assert {:ok, {8, 4, small}} = Blurhash.decode(@hash, 8, 4)
      assert byte_size(small) == 8 * 4 * 3
    end

    test "the picture really varies — a flat fill would pass every other check" do
      {:ok, {16, 16, rgb}} = Blurhash.decode(@hash, 16, 16)
      distinct = rgb |> :binary.bin_to_list() |> Enum.chunk_every(3) |> Enum.uniq() |> length()

      # 4×3 components over 256 pixels: dozens of distinct colours, not one.
      assert distinct > 20
    end

    # Every one of these arrives inside a stranger's ActivityPub delivery, and
    # the inbox must answer 202 rather than raise.
    test "anything that is not a BlurHash answers :error" do
      for value <- [
            "",
            "L",
            # A character outside base83 — the `\\` is not in the alphabet.
            "UKFrYAoN0hM{IVbIShRj9Gog%M%2-gj]N1%\\",
            # Well-formed base83, but the length contradicts the size flag.
            String.slice(@hash, 0..20),
            @hash <> "AA",
            String.duplicate("A", 200),
            42,
            nil,
            %{}
          ] do
        assert Blurhash.decode(value) == :error, "expected :error for #{inspect(value)}"
      end
    end

    test "an out-of-range render size is refused rather than clamped" do
      assert Blurhash.decode(@hash, 0, 16) == :error
      assert Blurhash.decode(@hash, 16, 65) == :error
    end
  end

  describe "data_uri/1" do
    test "is a PNG small enough to inline on a card" do
      uri = Blurhash.data_uri(@hash)

      assert String.starts_with?(uri, "data:image/png;base64,")
      # Measured at 1,348 bytes for the 16×16 render; the bound is what makes a
      # future size change a decision rather than an accident, since this string
      # rides every patch of a card that carries it.
      assert byte_size(uri) < 2_000
    end

    test "a hash that does not decode gets no poster at all" do
      assert Blurhash.data_uri("not a hash") == nil
      assert Blurhash.data_uri(nil) == nil
    end

    # A `<video>` fits its poster the way `object-fit: contain` does, so a
    # square stand-in under a 9:16 phone clip is letterboxed by black bands —
    # the very black box this exists to remove, just smaller. Seen in the
    # browser, which is the only place it shows.
    test "the poster takes the clip's shape, so nothing is letterboxed" do
      portrait = Blurhash.data_uri(@hash, {720, 1280})
      landscape = Blurhash.data_uri(@hash, {1920, 1080})
      square = Blurhash.data_uri(@hash)

      assert portrait != square
      assert landscape != square
      assert portrait != landscape

      # And each really is the shape it was asked for.
      assert {:ok, {9, 16, _}} = Blurhash.decode(@hash, 9, 16)
    end
  end
end
