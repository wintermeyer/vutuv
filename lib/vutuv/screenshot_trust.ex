defmodule Vutuv.ScreenshotTrust do
  @moduledoc """
  The sites whose link screenshots skip the AI image scan.

  Every capture — a profile link, a post's link, an organization's homepage —
  waits invisible until the local vision model has judged it
  (`Vutuv.Moderation.ImageScans`), because a screenshot of an NSFW page must
  not reach a public card. For a public broadcaster that scan is work without
  a question behind it, and at volume: on vutuv.de one news site accounted for
  44 % of all post-screenshot scans in summer 2026, and the model threw out two
  of its news photos as "drug paraphernalia". An admin lists such sites at
  **`/admin/screenshots?tab=trusted`**, and their captures are released the
  moment they are stored.

  Per-installation data like the blocklist (`Vutuv.ScreenshotBlocklist`), and
  empty on every installation until an admin fills it. It exempts a capture
  from the safety scan and nothing else: the page check that keeps cookie
  walls out of previews still runs, and the blocklist still wins.

  ## Narrower than the blocklist, on purpose

  The two lists err in opposite directions. A blocklist entry that covers too
  little is the worse mistake, so `heise.de` there covers every subdomain. A
  trust entry that covers too much is the worse mistake here: on a platform
  every subdomain belongs to somebody else (`substack.com`, `github.io`), and
  one line would wave all of them past the scan. So:

      tagesschau.de      # tagesschau.de and www.tagesschau.de, any path
      *.tagesschau.de    # the same, plus every other subdomain

  There are no path entries: trust is a statement about who runs a site, and a
  path narrows nothing about that.

  ## Where the browser ended up, not what was linked

  The decision is made on the pages the browser actually showed
  (`rendered_trusted?/1`, fed from the top frame's navigations by
  `Vutuv.PageScreenshot.Cdp`), never on the link a member posted. A redirect,
  a `<meta refresh>` or a script can carry the browser from a trusted site to
  any other, and an open redirect on a trusted site would otherwise be a way
  to publish an unscanned picture of anything. Every page the top frame
  committed must be trusted; a capture that recorded none is not.

  The check runs once per capture, after a Chromium run that took seconds, so
  it reads the table directly rather than through a cache.
  """

  import Ecto.Query

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Repo
  alias Vutuv.ScreenshotTrust.Host

  @doc "Every trusted site, alphabetically — what the admin page lists."
  def list_hosts, do: Repo.all(from(h in Host, order_by: [asc: h.host]))

  @doc "How many sites are trusted (the dashboard card's count)."
  def count_hosts, do: Repo.aggregate(Host, :count)

  @doc "Loads one entry by id, raising when it is gone."
  def get_host!(id), do: Repo.get!(Host, id)

  @doc "An empty changeset for the admin page's add form."
  def change_host, do: Host.changeset(%Host{}, %{})

  @doc """
  Adds a site. It applies to the next capture; screenshots already waiting for
  their scan keep waiting, which takes seconds.
  """
  def create_host(attrs), do: %Host{} |> Host.changeset(attrs) |> Repo.insert()

  @doc """
  Removes a site, so its captures are scanned again from the next one on.
  Screenshots released while it was trusted stay released.
  """
  def delete_host(%Host{} = host), do: Repo.delete(host)

  @doc """
  True when the host of `url` is on the list. Only `http` and `https`
  addresses can be: `about:blank` or a browser error page names no site.
  """
  def trusted?(url) when is_binary(url) do
    case host_of(url) do
      nil -> false
      host -> Repo.exists?(from(h in Host, where: h.host in ^candidates(host)))
    end
  end

  def trusted?(_url), do: false

  @doc """
  True when every page the browser's top frame showed during a capture is
  trusted — the question the capture pipeline asks. An empty list is `false`:
  a capture that recorded no page proves nothing about what it shows.
  """
  def rendered_trusted?([_ | _] = urls), do: Enum.all?(urls, &trusted?/1)
  def rendered_trusted?(_urls), do: false

  @doc """
  The moderation state a fresh capture starts in: released when the browser
  only showed trusted pages, otherwise whatever the AI gate says
  (`ImageScans.initial_state/0`). The capture itself is stored to match
  (`Vutuv.Screenshot.store/2` with `trusted:`), so a released one never enters
  quarantine.
  """
  def initial_moderation(true), do: "approved"
  def initial_moderation(false), do: ImageScans.initial_state()

  defp host_of(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        Host.canonical(host)

      _other ->
        nil
    end
  end

  # The entries that could cover `host`: the host itself, and a wildcard on it
  # or on any parent short of the top-level domain (the changeset refuses
  # `*.de`). One indexed lookup instead of loading the list.
  defp candidates(host) do
    labels = String.split(host, ".")

    wildcards =
      for n <- 0..(length(labels) - 2)//1, do: "*." <> Enum.join(Enum.drop(labels, n), ".")

    [host | wildcards]
  end
end
