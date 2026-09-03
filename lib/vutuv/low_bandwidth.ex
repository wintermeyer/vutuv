defmodule Vutuv.LowBandwidth do
  @moduledoc """
  Whether the page being rendered right now is for a member in data-saving
  mode (the `low_bandwidth?` preference, `Vutuv.Prefs`).

  The preference is the member's; what a renderer needs is the answer for
  *this* process. Which version of a picture goes into an `<img>` is decided
  deep inside a component that has no business being handed the viewer, so
  the answer lives in the process dictionary beside the Gettext locale and
  the viewer clock (`Vutuv.ViewerClock`), written by the same two writers:
  `VutuvWeb.Plug.Locale` on every browser request and `VutuvWeb.LiveLocale`
  on every LiveView mount. Both set it on every request, so nothing survives
  from an earlier request on a re-used process.

  A process that never ran either — a worker, an email render, an `iex`
  session — reads **off**, not the installation default: a lite picture is
  sent only to a viewer who is known to want one, and a render that has not
  resolved its viewer has no such viewer.

  ## What the mode changes

    * the composer: `VutuvWeb.UI.markdown_editor/1` asks `Prefs` directly, it
      holds the member; the 155 kB editor bundle is never named to the browser
    * every picture with a lite version in `Vutuv.Uploads.Spec` — a post photo
      (`Vutuv.Posts.PostImage.picture/2`), a picture from another network
      (`Vutuv.RemoteMedia.picture/1`), a URL screenshot
      (`Vutuv.Screenshot.picture/1`) and a profile cover
      (`Vutuv.Cover.picture/1`). Each answers `%{src:, lite:}`: the version
      the page always showed and, only while this flag is on and the lite file
      exists, the cheap one. `VutuvWeb.UI.picture/1` renders the pair as the
      lite picture with the SD/HD switch that swaps the full one in on request.
    * the lightbox opens a post photo at `large` (1600 px) rather than `xl`
      (2560 px): `Vutuv.Posts.PostImage.lightbox_url/1`.

  Measured on the production copy (2026-09-02, medians): a post photo's
  `feed` version is 44 kB, its lite 12 kB; a screenshot 13 kB against 3 kB; a
  cover 34 kB against 8 kB. Avatars stay as they are — the feed's 96 px avatar
  is 1.7 kB, and a softer one would save a kilobyte a face while blurring
  every name on the page.

  ## The cookie

  `cookie_name/0` names a plain `1` cookie the plug keeps in step with the
  preference, so a reverse proxy can tell these members' requests apart
  without asking the app — the hook for compressing their pages harder in
  nginx (`docs/ADMINS.md`, "Data-saving mode"). It carries nothing but the
  fact that the mode is on.
  """

  alias Vutuv.Prefs

  @key :vutuv_low_bandwidth
  @cookie "vutuv_low_bandwidth"

  @doc "The cookie a reverse proxy can read; its value is `\"1\"` while the mode is on."
  def cookie_name, do: @cookie

  @doc """
  Resolve and set the flag for `user` (or `nil`) in this process. Returns the
  resolved value, so the plug can keep the cookie in step without asking twice.
  """
  def put_viewer(user) do
    on? = Prefs.low_bandwidth?(user)
    put(on?)
    on?
  end

  @doc "Set the flag for this process. Tests use it to render as either kind of viewer."
  def put(on?) when is_boolean(on?) do
    Process.put(@key, on?)
    :ok
  end

  @doc "Whether the viewer this process renders for is in data-saving mode."
  def on?, do: Process.get(@key) == true

  @doc """
  The `%{src:, lite:}` pair `VutuvWeb.UI.picture/1` renders: `src` is the
  version the page always showed, `lite` the cheap one — only while this
  process renders for a viewer in the mode, and only if `lite_fun` finds one
  (`nil` otherwise). The four stores build their pair through here, so the
  gate is written once and `lite_fun`, which asks the disk, runs for nobody
  else.
  """
  def picture(src, lite_fun) when is_function(lite_fun, 0) do
    %{src: src, lite: if(on?(), do: lite_fun.())}
  end
end
