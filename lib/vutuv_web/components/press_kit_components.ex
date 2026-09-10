defmodule VutuvWeb.PressKitComponents do
  @moduledoc """
  What a member's or a page's press kit looks like on a **public** surface: the
  card below Links on the profile (#2086) and below the open positions on an
  organization page (#2087), and the section page that hands the files out.

  Its own module rather than more of `VutuvWeb.UI` because both owner kinds draw
  exactly the same two shelves, and the one thing that differs is the owner they
  are handed — so everything here takes pictures and a viewer and nothing else.
  The whole card is `press_card/1`, which #2087 lifted out of
  `templates/user/show.html.heex` when the page needed the second copy.

  ## What the card shows and what opens

  Photos lay themselves out as the **same bento mosaic** a photo post uses:
  `VutuvWeb.PostComponents.mosaic_layout/2` answers the geometry — hero first, a
  frame chosen from the hero's own shape, at most five tiles and a `+N` on the
  last — so the arrangements themselves are stated once for both. The grid's
  *markup* is still written twice, and knowingly. #2086 expected #2087 to be the
  third caller that pays for folding it into a shared component with a cell
  slot; it is not one. A page's card is this module's own `press_photos/1` at a
  second **call site**, not a third copy of the markup, so the count of copies
  is still two and the refactor of the app's hottest markup still has one
  surface to prove itself on. Leave it until a genuinely different grid needs
  the same geometry.

  A tile **describes** its photo and the magnifier in the corner **opens** it —
  the split `assets/js/lightbox.js` reads, and the reason a tile can sit inside
  the card's single link to the section page without swallowing the lightbox.

  ## The pixelated stand-in, and the index that goes with it

  A picture the AI gate has not released yet is drawn, not skipped: its owner
  sees the real photo and a stranger the pixelated tile (#2084), which is
  `Vutuv.PressKit.visible_to?/2` asked once per tile. Where there is no stand-in
  on disk — the window has run out, the installation writes none — the tile is
  the grey "being checked" box the post card draws in the same situation.

  The trap that comes with it: `lightbox.js` builds its gallery from the
  elements carrying a `data-photo-src`, so a held tile is **not** in it, and a
  `data-lightbox-photo` counted over all the tiles would open the wrong picture
  the moment one of them is still waiting. `views/2` therefore numbers the
  visible pictures alone, and a held tile carries neither attribute.

  ## The logos' ground

  Every logo tile stands on **white, in both themes**. #2085 deliberately stored
  nothing about which ground a variant was drawn for (that would be a column,
  and its editor's light/dark switch is a preview of the whole shelf), so the
  public surfaces cannot know — and a tile that followed the reader's theme
  would make the variant drawn for light grounds vanish for half of them. White
  is the editor's own default, the variant label under the tile says which
  variant it is, and the section page shows each logo a second time on a dark
  ground so a reversed mark is visible somewhere.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  import VutuvWeb.UI

  alias Vutuv.Images.Image
  alias Vutuv.Moderation
  alias Vutuv.PressKit
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.Markdown
  alias VutuvWeb.PostComponents

  @doc """
  The whole **Press card**: the photo mosaic, the logo row, the rights line and
  the footer link to the section page — on a member's profile below Links, and
  on a page below its open positions.

  `manage_href` is the editor (`Vutuv.PressKit.editor_path/1`) when this viewer
  may write the kit and `nil` when they may not, which is the only thing the two
  surfaces disagree about: it decides whether an empty kit shows the card at all
  and what the dashed add tile links to. Every other difference lives in the
  owner, and `page_path/1` answers it.
  """
  attr(:id, :string, required: true)
  attr(:owner, :any, required: true, doc: "the member or the page whose kit this is")
  attr(:press, :map, required: true, doc: "`Vutuv.PressKit.public_shelves/2`'s answer")
  attr(:viewer, :any, default: nil)
  attr(:manage_href, :any, default: nil)

  def press_card(assigns) do
    # `Map.put/3`, not `assign/3`: a card's owner cannot change without a fresh
    # mount, so the key needs no change mark and the attributes reading it stay
    # separately tracked.
    assigns = Map.put(assigns, :href, PressKit.page_path(assigns.owner))

    ~H"""
    <.card :if={press_any?(@press) or @manage_href} id={@id}>
      <.section_header title={gettext("Press")} />
      <.empty_add :if={@manage_href && not press_any?(@press)} href={@manage_href}>
        {gettext("Add press photos")}
      </.empty_add>
      <div :if={press_any?(@press)} class="space-y-4">
        <.press_photos
          :if={@press.photos != []}
          photos={@press.photos}
          viewer={@viewer}
          href={@href}
        />
        <.press_logos :if={@press.logos != []} logos={@press.logos} viewer={@viewer} />
        <.press_rights />
      </div>
      <%!-- Not `<.manage_footer>`: that one hides the "View All" link until a
      card shows less than it holds, and here the section page is not a longer
      list of the same thing — it is where the files are handed over, so every
      visitor needs it whatever the count. The owner's bridge to the editor is
      the "Manage" link in that page's own header. --%>
      <.card_footer_link :if={press_any?(@press)} href={@href}>
        {gettext("All press material")} ({compact_count(press_total(@press))})
      </.card_footer_link>
    </.card>
    """
  end

  @doc """
  How many press pictures this kit holds altogether — both shelves, since the
  card shows both and its footer counts what it shows.
  """
  def press_total(%{photos: photos, logos: logos}), do: length(photos) + length(logos)

  @doc "Whether there is anything on either shelf."
  def press_any?(press), do: press_total(press) > 0

  @doc """
  The rights line on the **card**: the one sentence that makes the download
  usable, since a press kit that says nothing about reuse is a folder of
  pictures a journalist may not print. The section page has the room to say it
  at length in its own words; what must not differ is the terms, and those come
  from `Vutuv.PressKit.rights_line/0` here, in the lightbox, in the schema.org
  block and in the agent documents alike.
  """
  attr(:class, :any, default: nil)

  def press_rights(assigns) do
    ~H"""
    <p class={["text-xs text-slate-500 dark:text-slate-400", @class]} data-press-rights>
      {PressKit.rights_line()}
    </p>
    """
  end

  @doc """
  The card's photo mosaic. `href` is where a tap on a tile goes (the section
  page); the magnifier opens the lightbox over the tiles instead.
  """
  attr(:photos, :list, required: true)
  attr(:viewer, :any, default: nil)
  attr(:href, :string, required: true)

  def press_photos(assigns) do
    layout = PostComponents.mosaic_layout(assigns.photos)
    views = views(Enum.map(layout.cells, & &1.image), assigns.viewer)
    cells = Enum.zip_with(layout.cells, views, &Map.merge/2)

    assigns =
      assigns
      |> assign(:cells, cells)
      |> assign(:corner, corner_photo(cells, PostComponents.mosaic_corner_index(layout.cells)))
      |> assign(:frame, layout.aspect)

    ~H"""
    <.lightbox_gallery class="hover-reveal-host relative" data-press-photos>
      <.link
        href={@href}
        aria-label={gettext("All press photos")}
        class="grid gap-1 overflow-hidden rounded-lg"
        style={"aspect-ratio: #{@frame}; grid-template-columns: repeat(12, 1fr); grid-template-rows: repeat(6, 1fr); max-height: 44rem"}
      >
        <%!-- The `data-photo-*` names are spelled out rather than spread from
        `photo_data/3`'s map: a literal attribute name is hoisted into this
        template's statics, while a spread sends every one of them down the wire
        on each render (`VutuvWeb.PostComponents.photo_data/4` measured +875
        bytes per card). --%>
        <div
          :for={cell <- @cells}
          class="relative overflow-hidden bg-slate-100 ring-1 ring-slate-200 dark:bg-slate-800 dark:ring-slate-800"
          style={"grid-area: #{cell.area}"}
          data-photo-src={cell.photo[:src]}
          data-photo-alt={cell.photo[:alt]}
          data-photo-caption={cell.photo[:caption]}
          data-photo-credit={cell.photo[:credit]}
          data-photo-download={cell.photo[:download]}
          data-photo-license={cell.photo[:license]}
          data-photo-position={cell.photo[:position]}
          data-photo-report={cell.report}
        >
          <.press_tile image={cell.image} held={cell.held} class="h-full w-full object-cover" />
          <span
            :if={cell.more > 0}
            class="absolute inset-0 flex items-center justify-center bg-slate-900/55 text-2xl font-semibold text-white"
            data-press-more
          >
            +{compact_count(cell.more)}
          </span>
        </div>
      </.link>
      <%!-- No corner while every photo is still being checked: there is nothing
      behind the tiles to enlarge, and a magnifier that opens an empty overlay
      is worse than none. --%>
      <.zoom_corner :if={@corner} label={gettext("Show these photos larger")} index={@corner} />
    </.lightbox_gallery>
    """
  end

  @doc """
  The card's logo row: one tile per variant, each on white, with the variant
  label under it.
  """
  attr(:logos, :list, required: true)
  attr(:viewer, :any, default: nil)

  def press_logos(assigns) do
    assigns = assign(assigns, :views, views(assigns.logos, assigns.viewer))

    ~H"""
    <ul class="flex flex-wrap gap-3" data-press-logos>
      <li :for={view <- @views} class="w-28">
        <span class="flex h-20 items-center justify-center overflow-hidden rounded-lg bg-white p-2 ring-1 ring-slate-200 dark:ring-slate-700">
          <.press_tile image={view.image} held={view.held} class="h-full w-full object-contain" />
        </span>
        <span
          :if={variant_label(view.image)}
          class="mt-1 block truncate text-xs text-slate-500 dark:text-slate-400"
        >
          {variant_label(view.image)}
        </span>
      </li>
    </ul>
    """
  end

  @doc """
  One press photo on the section page, whole: the picture, then the caption, the
  credit, the dimensions, the file size and a finger-sized Download.

  The picture is the lightbox's own control here (`data-lightbox-photo` on the
  anchor), the way the post permalink's photos are: this page **is** the photos,
  so a magnifier of its own would be a second control for the same tap.
  """
  attr(:view, :map, required: true, doc: "one entry of `views/2`")

  def press_photo_entry(assigns) do
    ~H"""
    <li class="py-6 first:pt-0" data-press-photo>
      <%!-- One anchor for both cases: HEEx drops an attribute whose value is
      `nil`, so a held picture renders the same box without an href, without a
      `data-photo-src` (which is what keeps it out of the lightbox's gallery)
      and without the zoom cursor that would promise a tap. --%>
      <a
        href={@view.photo[:src]}
        class={[
          "block overflow-hidden rounded-lg ring-1 ring-slate-200 dark:ring-slate-800",
          @view.photo && "cursor-zoom-in"
        ]}
        data-lightbox-photo={@view.photo[:index]}
        data-photo-src={@view.photo[:src]}
        data-photo-alt={@view.photo[:alt]}
        data-photo-caption={@view.photo[:caption]}
        data-photo-credit={@view.photo[:credit]}
        data-photo-download={@view.photo[:download]}
        data-photo-license={@view.photo[:license]}
        data-photo-position={@view.photo[:position]}
        data-photo-report={@view.report}
      >
        <.press_tile image={@view.image} held={@view.held} class="block h-auto w-full" />
      </a>

      <.press_meta image={@view.image} report={@view.report} />
      <.press_download :if={@view.photo} href={PressKit.download_url(@view.image)}>
        {gettext("Download photo")}
      </.press_download>
    </li>
    """
  end

  @doc """
  One logo variant on the section page: the mark on both grounds, its label, and
  a download per format — the vector where there is one, and the PNG beside it
  for whoever cannot use a vector.
  """
  attr(:view, :map, required: true, doc: "one entry of `views/2`")

  def press_logo_entry(assigns) do
    ~H"""
    <li
      class="py-6 first:pt-0"
      data-press-logo
    >
      <%!-- The same file on both grounds — see the moduledoc for why neither of
      them can be the one it was drawn for. --%>
      <div class="flex flex-wrap gap-3">
        <span
          :for={ground <- ~w(bg-white bg-slate-900)}
          class={[
            "flex h-24 w-40 items-center justify-center overflow-hidden rounded-lg p-3 ring-1 ring-slate-200 dark:ring-slate-700",
            ground
          ]}
        >
          <.press_tile image={@view.image} held={@view.held} class="h-full w-full object-contain" />
        </span>
      </div>

      <p
        :if={variant_label(@view.image)}
        class="mt-3 text-sm font-medium text-slate-800 dark:text-slate-100"
      >
        {variant_label(@view.image)}
      </p>

      <.press_meta image={@view.image} report={@view.report} />

      <div :if={@view.photo} class="flex flex-wrap gap-2">
        <.press_download href={PressKit.download_url(@view.image)}>
          {gettext("Download %{format}", format: format_name(@view.image))}
        </.press_download>
        <.press_download :if={vector?(@view.image)} href={PressKit.png_download_url(@view.image)}>
          {gettext("Download %{format}", format: "PNG")}
        </.press_download>
      </div>
    </li>
    """
  end

  @doc """
  Each picture with what this viewer may be told about it: `image`, `held`
  (`false` for the real picture, a stand-in URL, or `:none` for the grey box)
  and `photo` — the facts the lightbox reads, including the picture's `index` in
  that gallery, or `nil` for a picture the viewer may not see.

  One field says which case a tile is: `photo` is there exactly when `held` is
  `false`. Held pictures are numbered out of the gallery, deliberately — see the
  moduledoc.
  """
  def views(images, viewer) do
    shown = Enum.map(images, &{&1, PressKit.visible_to?(&1, viewer)})
    visible = Enum.count(shown, &elem(&1, 1))
    scope = report_scope(images, viewer)

    {views, _next} =
      Enum.map_reduce(shown, 0, fn
        {image, true}, next ->
          {%{
             image: image,
             held: false,
             photo: photo_data(image, next, visible),
             report: report_href(image, scope)
           }, next + 1}

        {image, false}, next ->
          {%{image: image, held: PressKit.pixelated_url(image) || :none, photo: nil, report: nil},
           next}
      end)

    views
  end

  # Where a Report control on this picture goes, or `nil` when this reader is
  # offered none (issue #2089).
  #
  # Two addresses, because a press kit is published *at* people who mostly have
  # no account here: a signed-in member files in-app, and everybody else gets
  # the public notice form with the picture's own address already filled in.
  # The notice form takes a pasted address, so the link hands it one, absolute —
  # that is what `Vutuv.Moderation.ContentUrl` parses back.
  defp report_href(%Image{}, nil), do: nil

  defp report_href(%Image{} = image, :public),
    do: ~p"/system/report?#{[url: AgentDocs.abs_url(PressKit.preview_url(image))]}"

  defp report_href(%Image{} = image, {:member, return_to}),
    do: image_report_path(image.id, return_to)

  # Asked **once per shelf**, not once per picture: every question here is about
  # the owner, and every picture on a shelf has the same one. The first row is
  # therefore as good as all of them.
  #
  # None of it is a query for an anonymous reader: the shelf arrived with its
  # owner on every row (`public_shelves/2`), `manageable_by?/2` answers a
  # viewerless call from a clause, and "is there anybody to hold accountable"
  # is asked of the **owner** rather than of the picture, which is a column on
  # a row already in memory. A signed-in reader on a page's kit pays one role
  # read for it.
  defp report_scope([], _viewer), do: nil

  defp report_scope([%Image{} = image | _rest], viewer) do
    owner = PressKit.owner(image)

    cond do
      is_nil(owner) -> nil
      PressKit.manageable_by?(owner, viewer) -> nil
      not Moderation.reportable?(owner) -> nil
      is_nil(viewer) -> :public
      true -> {:member, PressKit.page_path(owner)}
    end
  end

  @doc """
  The pictures of these views a **crawler** may be told about: the released
  ones. What the page's schema.org block names.

  **Hand it the anonymous views** (`views(images, nil)`), never the reader's: the
  markup describes the page to a machine, which is always anonymous, and an owner
  or an admin is shown a picture the AI gate still holds — publishing its
  `contentUrl` here would name an address that answers 404 to everybody else.
  Viewer-dependence is the failure mode, so the caller's `nil` is the whole
  guard.
  """
  def public_pictures(views), do: for(%{held: false, image: image} <- views, do: image)

  @doc """
  The dimensions and the file size of one picture, the two facts a journalist
  checks before downloading. The size goes through `VutuvWeb.UI.file_size/1`, so
  it reads `2,4 MB` rather than as a run of digits.
  """
  def facts_line(%Image{} = image) do
    [dimensions(image), image.size_bytes && file_size(image.size_bytes)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc """
  What the lightbox is told about one press photo, in one place, so the card's
  tiles and the section page's anchors cannot describe the same picture
  differently. `xl` is the version the overlay opens, the same one a post photo
  opens at.
  """
  def photo_data(%Image{} = image, index, count) do
    %{
      index: index,
      src: PressKit.lightbox_url(image),
      alt: image.alt || "",
      # The overlay writes every field with `textContent`, so a caption has to
      # arrive as prose: the stored value is Markdown (the photographer's
      # `@handle` links to their profile on the page below), and a literal `**`
      # in the one place a journalist reads the caption is a rendering fault.
      caption: Markdown.to_plain_text(image.caption),
      credit: image.credit,
      download: PressKit.download_url(image),
      license: PressKit.rights_line(),
      position: gettext("Photo %{n} of %{total}", n: index + 1, total: count)
    }
  end

  # The caption, the credit, the two file facts and — last, quiet, and a plain
  # link rather than a control — the way to report the picture. It rides this
  # line rather than standing beside the Download button on purpose: a press
  # kit is published for people to take, and the one act nobody should have to
  # hunt for still must not sit at the same weight as the act the page exists
  # for.
  attr(:image, :any, required: true)
  attr(:report, :any, default: nil)

  defp press_meta(assigns) do
    ~H"""
    <.markdown_prose
      :if={present?(@image.caption)}
      text={@image.caption}
      class="mt-3 text-sm text-slate-700 dark:text-slate-300"
    />
    <p class="mt-2 text-xs text-slate-500 dark:text-slate-400">
      <span :if={present?(@image.credit)} data-press-credit>{@image.credit}</span>
      <span :if={present?(@image.credit)} aria-hidden="true">·</span>
      <span data-press-facts>{facts_line(@image)}</span>
      <span :if={@report} aria-hidden="true">·</span>
      <a
        :if={@report}
        href={@report}
        class="underline underline-offset-2 hover:text-slate-700 dark:hover:text-slate-200"
        data-press-report
      >
        {gettext("Report this picture")}
      </a>
    </p>
    """
  end

  # A finger-sized download button — the whole point of the page, so it is a
  # button and not a link inside a sentence. `<.button>` owns the recipe (the
  # 40px height included); only the top margin is this call site's.
  attr(:href, :string, required: true)
  slot(:inner_block, required: true)

  defp press_download(assigns) do
    ~H"""
    <.button href={@href} class="mt-3" download data-press-download>
      {render_slot(@inner_block)}
    </.button>
    """
  end

  # One picture inside whatever box the caller drew: the real one for a reader
  # allowed to see it, the pixelated stand-in for a stranger while the AI check
  # runs, and the grey "being checked" box where no stand-in was written.
  attr(:image, :any, required: true)
  attr(:held, :any, required: true, doc: "`false`, a stand-in URL, or `:none`")
  attr(:class, :any, default: nil)

  defp press_tile(%{held: false} = assigns) do
    ~H"""
    <.picture
      picture={PressKit.picture(@image)}
      wrap_class="h-full w-full"
      alt={@image.alt || ""}
      width={@image.width}
      height={@image.height}
      loading="lazy"
      class={@class}
    />
    """
  end

  # The stand-in describes nothing — inventing a description of a picture nobody
  # has looked at yet would be a lie in the one place a reader cannot check it —
  # so the badge beside it is what carries the information, exactly as it does
  # on a post card's held photo.
  defp press_tile(%{held: :none} = assigns) do
    ~H"""
    <span
      class="flex aspect-[4/3] w-full flex-col items-center justify-center gap-2 bg-slate-100 px-3 text-center dark:bg-slate-800"
      data-press-held
    >
      <.hourglass class="h-7 w-7 text-slate-500 dark:text-slate-400" />
      <span class="text-xs font-semibold text-slate-700 dark:text-slate-200">
        {gettext("Photo is being checked")}
      </span>
    </span>
    """
  end

  defp press_tile(assigns) do
    ~H"""
    <span class="relative block h-full w-full" data-press-pixelated>
      <img
        src={@held}
        alt=""
        width={@image.width}
        height={@image.height}
        loading="lazy"
        class={@class}
      />
      <.checking_badge class="absolute bottom-1 left-1" />
    </span>
    """
  end

  # Which picture the magnifier opens: the one lying under it, or the first
  # visible one when that tile is still being checked. `nil` when none is.
  defp corner_photo(cells, corner_index) do
    under = Enum.find(cells, &(&1.index == corner_index))

    (under && under.photo[:index]) || Enum.find_value(cells, & &1.photo[:index])
  end

  # The variant label is `images.alt` (#2085 settled it there rather than in a
  # column of its own), so it doubles as the tile's alt text.
  defp variant_label(%Image{alt: alt}) when is_binary(alt) and alt != "", do: alt
  defp variant_label(%Image{}), do: nil

  defp dimensions(%Image{width: w, height: h}) when is_integer(w) and is_integer(h),
    do: "#{w} × #{h}"

  defp dimensions(%Image{}), do: nil

  # SVG only ever leaves as an attachment (#2083), so a vector variant offers
  # the PNG rendering beside it.
  defp vector?(%Image{content_type: "image/svg+xml"}), do: true
  defp vector?(%Image{}), do: false

  defp format_name(%Image{content_type: "image/svg+xml"}), do: "SVG"
  defp format_name(%Image{}), do: "PNG"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
