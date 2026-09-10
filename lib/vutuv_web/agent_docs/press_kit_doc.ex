defmodule VutuvWeb.AgentDocs.PressKitDoc do
  @moduledoc """
  A member's or a page's Media Kit (`/:slug/media-kit`) as a data map for the agent
  formats — the page's `.md`, `.txt`, `.json` and `.xml` siblings (issue #2086,
  which #2088 folded into).

  A **bespoke** doc type rather than one of `VutuvWeb.AgentDocs.SectionDocs`'
  uniform entry lists, for three reasons that all point the same way: this page
  carries two shelves rather than one list, it has no per-entry show page (the
  entry *is* a file, and the file has its own URL), and it is the one page under
  a member's slug that is **not** noindexed — a press kit exists to be found, so
  its doc mirrors the profile's own opt-outs instead of the section pages' flat
  `noindex: true`.

  What an agent gets that the HTML page does not spell out as plainly: every
  picture's absolute download URL, its pixel dimensions and byte size, and the
  one rights sentence in a field of its own — enough to fetch a printable file
  and credit it correctly without reading a page.

  A picture still waiting on the AI check is **absent** from every format
  (`Vutuv.PressKit.published_shelves/1` is what the callers hand over). The HTML
  page shows its owner the real picture and a stranger the pixelated tile, but a
  download URL that answers 404 is worse than a shorter list.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Identity
  alias Vutuv.Images.Image
  alias Vutuv.PressKit
  alias VutuvWeb.AgentDocs

  @doc """
  The press page as a doc map. `shelves` is `Vutuv.PressKit.published_shelves/1`'s
  answer — the released pictures, which is the set a document may name at all.
  `bio` is `Vutuv.PressKit.bio/1`'s, the three lengths the owner wrote.

  Both are **arguments** rather than reads of this module's own: the HTML page
  needs the same two, and a builder that fetched them again would make an agent
  format cost two queries the page has already paid for.
  """
  def build(owner, shelves, bio) do
    name = Identity.display_name(owner)
    photos = entries(shelves.photos)
    logos = entries(shelves.logos)
    {noindex?, noai?} = PressKit.robots_axes(owner)

    AgentDocs.doc_meta("press_kit", PressKit.page_path(owner),
      noindex: noindex?,
      noai: noai?
    )
    |> Map.merge(%{
      title: gettext("Media Kit of %{name}", name: name),
      description:
        gettext("Press pictures %{name} offers for download, free for editorial use with credit.",
          name: name
        ),
      owner: AgentDocs.person_ref(owner),
      rights: PressKit.rights_line(),
      total: length(photos) + length(logos),
      # The bios the owner wrote (issue #2101) — a **list** rather than three
      # keys, so a kit with only a medium one renders without a branch anywhere
      # and every format keeps the order the page shows. The text is the
      # Markdown source: an agent reading a `.md` document wants the marks, and
      # a `@handle` in it names an account it can go and fetch.
      bios: PressKit.bio_entries(bio),
      photos: photos,
      logos: logos
    })
  end

  @doc "One shelf as entries — the vocabulary the profile document shares."
  def entries(images), do: Enum.map(images, &entry/1)

  @doc """
  One picture, the vocabulary the profile doc's `press_kit` list shares — so a
  press photo is described the same way whether an agent reads the profile or
  the press page.
  """
  def entry(%Image{} = image) do
    %{
      id: image.id,
      # A picture whose owner typed no label still has to be called something,
      # and what it is called is decided by the **shelf** it is on (issue #2142).
      # The fallback used to live in each renderer, which sees a flat map and so
      # could only ever say "Press picture" — under a heading reading "Logo
      # variants", to a picture desk pulling logos by title. The row knows which
      # shelf it is on, so `PressKit.title/1` answers for the editor's tile and
      # the report form too rather than a third time here.
      label: PressKit.title(image),
      caption: image.caption,
      credit: image.credit,
      content_type: image.content_type,
      # The bytes the download really hands over, not the upload's length: a
      # photo is stripped of its metadata on the way out (issue #2140).
      size_bytes: PressKit.download_bytes(image),
      preview_url: AgentDocs.abs_url(PressKit.url(image, "large")),
      download_url: AgentDocs.abs_url(PressKit.download_url(image)),
      # Only a vector logo has one; a photo's download is already the file
      # itself, and an absent fact is no key at all rather than null.
      png_download_url: png_url(image)
    }
    |> Map.merge(pixel_size(image))
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  # `width`/`height` describe whatever `download_url` hands over — except for a
  # vector, which has no pixel size of its own: there the stored numbers are the
  # rasterisation's, i.e. the PNG offered beside it, so they are named after it.
  defp pixel_size(%Image{} = image) do
    if PressKit.vector?(image),
      do: %{png_width: image.width, png_height: image.height},
      else: %{width: image.width, height: image.height}
  end

  # The same question `pixel_size/1` asks, so the two keys travel together: an
  # entry carries `png_width`/`png_height` exactly when it carries the PNG.
  defp png_url(%Image{} = image),
    do: if(PressKit.vector?(image), do: AgentDocs.abs_url(PressKit.png_download_url(image)))
end
