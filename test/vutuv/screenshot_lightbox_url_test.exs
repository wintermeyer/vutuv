defmodule Vutuv.ScreenshotLightboxUrlTest do
  @moduledoc """
  What the magnifier on a page capture opens (`Vutuv.Screenshot.lightbox_url/1`).

  The card follows data-saving mode and shows the 400×264 lite; the overlay
  does not, and that asymmetry is the whole point. `PostImage.lightbox_url/1`
  steps a *photo* down for such a viewer because a photo has a step to take —
  its 2560px version exists for a screen they most likely do not hold. A
  capture has none: below the thumb there is only the file already on screen,
  so opening that would paint the same bytes full screen and answer a tap that
  asked for detail with blur.

  `async: false` — flips `:uploads_dir_prefix` and `:low_bandwidth`, neither of
  which the SQL sandbox rolls back.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.LowBandwidth
  alias Vutuv.Screenshot

  @hash "abcdef012345"

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_lightbox_url_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    scope = %{id: Vutuv.UUIDv7.generate(), screenshot: "#{@hash}.png", screenshot_moderation: nil}
    dir = Path.join([tmp, "screenshots", scope.id])
    File.mkdir_p!(dir)
    for name <- ~w(thumb lite), do: File.write!(Path.join(dir, "#{name}-#{@hash}.avif"), "x")

    {:ok, scope: scope}
  end

  test "the card follows data-saving mode", %{scope: scope} do
    refute Screenshot.picture({scope.screenshot, scope}).lite

    with_low_bandwidth(fn ->
      assert Screenshot.picture({scope.screenshot, scope}).lite =~ "lite-#{@hash}"
    end)
  end

  test "the overlay opens the thumb in either mode", %{scope: scope} do
    assert Screenshot.lightbox_url({scope.screenshot, scope}) =~ "thumb-#{@hash}"

    with_low_bandwidth(fn ->
      assert Screenshot.lightbox_url({scope.screenshot, scope}) =~ "thumb-#{@hash}"
    end)
  end

  # `Vutuv.LowBandwidth` reads the mode off the process dictionary, the way the
  # request pipeline puts it there.
  defp with_low_bandwidth(fun) do
    LowBandwidth.put(true)
    fun.()
  after
    LowBandwidth.put(false)
  end
end
