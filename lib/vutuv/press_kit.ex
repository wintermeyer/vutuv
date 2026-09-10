defmodule Vutuv.PressKit do
  @moduledoc """
  The press photos and logo variants a member or a page offers for download
  (issue #2083, the foundation of #2082).

  A press picture is a row on the shared `images` table with `kind` `"press_kit"`
  — **born** there, unlike every kind before it: #2015's four arrived as a
  mirror of a table of their own and the review cover as columns on a parent
  row, so this is the first one with no source to keep in step, no backfill
  class and no contract release. `Vutuv.Images` registers it (`serving/1` says
  `:proxy`); this module owns everything about it that is not a column.

  ## Two shelves, one kind

  A row is a **photo** (`logo: false`) or a **logo variant** (`logo: true`).
  They are one kind rather than two because everything the rest of the system
  asks about a picture — who owns it, its token, its moderation state, its
  takedown, the proxy it goes through — is identical, and a second kind would
  have to be registered a second time in every list #2084 and #2089 extend.
  What differs is only what each shelf may hold and how many:

    * a photo is JPEG, PNG or WebP — exactly the containers
      `Vutuv.Uploads.MetadataStrip` can take apart, because the download is the
      cleaned original;
    * a logo is SVG or PNG, and the vector leaves only as an attachment beside
      a PNG rendering (`Vutuv.PressKitStore`);
    * the caps are counted per shelf, so a full logo shelf costs a member
      nothing on the photo one.

  ## Who owns one

  A member's press kit is theirs and dies with the account (`images.user_id`,
  `ON DELETE CASCADE`, plus the files `Vutuv.Accounts.delete_user/1` collects).
  A page's belongs to the **page**: `organization_id` owns it, the uploader
  rides in `uploader_user_id` and is nulled when their account goes, exactly as
  #2053 settled for an organization logo — so a press photo never vanishes with
  the colleague who uploaded it. Naming both would arm the member cascade on a
  picture the page owns, which is why the database refuses it
  (`images_press_kit_has_one_owner`).

  ## Born pending, and how it gets out (issue #2084)

  A fresh row starts at `Vutuv.Moderation.ImageScans.initial_state/0`, so on an
  installation with the AI gate on it is `"pending"`, `visible_to?/2` shows it
  to its owner alone, and `create/4` queues the scan that has to clear it. Until
  a verdict lands a stranger gets the **pixelated stand-in** (`pixelated_url/1`)
  rather than nothing, for the window `Vutuv.Moderation.Pixelation` measures
  from the upload — this row *is* the upload, so `inserted_at` is the honest
  clock and no mirror row can lie about it. A rejection wipes every byte and
  tells whoever uploaded it; a copyright case can freeze one from the first day
  it exists (`Vutuv.Images.freeze/1`), because a picture published for
  redistribution is the likeliest of all of them to draw a notice.
  """

  use Gettext, backend: VutuvWeb.Gettext

  import Ecto.Query, warn: false
  import Vutuv.Identity.Query, only: [party_is: 2]

  alias Vutuv.Accounts.User
  alias Vutuv.Identity
  alias Vutuv.Identity.Query
  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.LowBandwidth
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Moderation.Pixelation
  alias Vutuv.Ordering
  alias Vutuv.OrganizationImageStore
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.PressKitStore
  alias Vutuv.Repo
  alias Vutuv.Uploads

  @kind "press_kit"

  @doc "This kind's name in `Vutuv.Images.kinds/0`."
  def kind, do: @kind

  ## Caps and formats ---------------------------------------------------------

  @doc """
  How many press photos one member or page may offer. Ten is enough for a
  portrait, a working shot, a stage picture and a handful of situations, and few
  enough that a journalist can look at all of them.
  """
  def max_photos, do: Keyword.get(config(), :max_photos, 10)

  @doc """
  How many logo variants one member or page may offer. Five covers the set a
  design manual actually names — the mark for light backgrounds, the one for
  dark, a monochrome, a square icon — with one spare.
  """
  def max_logos, do: Keyword.get(config(), :max_logos, 5)

  @doc """
  The largest file either shelf accepts, in bytes. 30 MB is a full-frame RAW
  export as JPEG, which is what a photographer hands over; the download is the
  point of the feature, so the cap has to admit a printable file rather than a
  screen-sized one.
  """
  def max_filesize, do: Keyword.get(config(), :max_filesize, 30_000_000)

  @doc "What a press photo may be uploaded as."
  defdelegate photo_extensions, to: PressKitStore

  @doc "What a logo variant may be uploaded as."
  defdelegate logo_extensions, to: PressKitStore

  defp config, do: Application.get_env(:vutuv, :press_kit, [])

  ## Reading ------------------------------------------------------------------

  @doc "The owner's press photos, in the order they are shown (the first is the hero)."
  def photos(owner), do: shelf_rows(owner, false)

  @doc "The owner's logo variants, in the order they are shown."
  def logos(owner), do: shelf_rows(owner, true)

  @doc """
  Both shelves of one owner's kit **whatever their moderation state** —
  `%{photos:, logos:}`, each in the owner's own order. What the editor lists,
  which is the one surface that shows a picture the AI gate is still holding as
  itself rather than as a stand-in.

  One query for both, for `public_shelves/2`'s reason: the caps are ten and five,
  so the whole kit is at most fifteen rows and the split is cheaper in memory
  than a second round trip — and the editor reloads them after every save,
  delete, move, reorder and upload.
  """
  def shelves(owner) do
    owner |> owned() |> Ordering.by_position() |> Repo.all() |> split()
  end

  @doc "How many pictures the owner has on that shelf."
  def count(owner, logo?) when is_boolean(logo?),
    do: owner |> shelf(logo?) |> Repo.aggregate(:count)

  @doc """
  One owner's press kit as the two shelves a public surface draws
  (`%{photos: [...], logos: [...]}`, each in the owner's own order, the first
  photo the hero) — the profile card and the section page of #2086, and #2087's
  page twin.

  **One query for both shelves**, not one per shelf: the caps are ten and five,
  so the whole kit is at most fifteen rows and the split is cheaper in memory
  than a second round trip on a page that already makes several.

  Every row comes back with its owner set on the association, because the owner
  is the argument — so `visible_to?/2`, `pixelated_url/1` and `download_name/2`
  each cost nothing per picture rather than one `Repo.get/2`.

  A picture is on the list when this viewer may see it **or** when the stand-in
  may stand where it is (#2084): a stranger meets the pixelated tile while the
  AI check runs and the owner meets the real picture, which is what
  `showable?/2` states once for both surfaces. A frozen picture is on neither
  list, for anybody, because a takedown has to read like a picture that was
  never there.
  """
  def public_shelves(owner, viewer) do
    owner
    |> owned()
    |> Ordering.by_position()
    |> Repo.all()
    |> Enum.map(&put_owner(&1, owner))
    |> Enum.filter(&showable?(&1, viewer))
    |> split()
  end

  @doc """
  Whether a public surface draws this picture at all — the real one, or the
  pixelated stand-in in its place.

  The one statement of "is there a tile here", so the card, the section page and
  the agent documents cannot answer it three ways. Which of the two a reader
  gets is `visible_to?/2` again at the tile itself.
  """
  def showable?(%Image{kind: @kind} = image, viewer),
    do: visible_to?(image, viewer) or pixelated_visible?(image)

  def showable?(_image, _viewer), do: false

  @doc """
  The **released** shelves: `%{photos:, logos:}` of the pictures the AI gate has
  let out, in the owner's order.

  What a *document* is built from (`VutuvWeb.AgentDocs.PressKitDoc`, the profile
  document's `press_kit` list) and what the page's schema.org markup names,
  because a document that offers a file must offer one that can be fetched — a
  picture still in the queue answers 404 at every one of its addresses. The HTML
  page is the other question and asks `public_shelves/2`, which keeps the
  waiting pictures and stands in for them.
  """
  def published_shelves(owner) do
    owner |> owned() |> released() |> Ordering.by_position() |> Repo.all() |> split()
  end

  @doc """
  The press-kit rows a crawler may meet, table-wide: released by the AI gate and
  not frozen. What `Vutuv.Sitemap.press_entries/1` asks of the whole table.

  The rule is `Vutuv.Moderation.ImageScans.released?/1`'s plus the freeze — not
  `Vutuv.Images.servable?/1`'s, which only excludes `"pending"` and would
  therefore serve a rejected row. `released/1` below is the one SQL spelling
  here; `Vutuv.Social.newest_members_with_avatar/1` carries its own copy of the
  same pair for the avatar strip, which is worth folding the day a third one
  appears.
  """
  def public_query, do: released(from(i in Image, where: i.kind == ^@kind))

  @doc """
  The two robots axes for an owner's press page: `{noindex?, noai?}`.

  A press kit is published in order to be found, so the page carries the
  **owner's own** opt-outs rather than the blanket refusal every other
  profile sub-page wears. Stated once here because the controller sets the
  header from it and the agent documents stamp their `Content-Signal` from it,
  and `VutuvWeb.AgentDocs.PostDoc.robots_axes/2`'s docstring is the war story of
  what happens when two such derivations disagree.
  """
  def robots_axes(%User{} = user), do: {user.noindex?, user.noai?}
  def robots_axes(%Organization{} = organization), do: {not organization.seo?, false}

  @doc """
  A shelf's own word, the one token the DOM, the event names and the data
  export all use for it — so the two spellings of "photo or logo" cannot drift.
  """
  def shelf_name(true), do: "logo"
  def shelf_name(false), do: "photo"
  def shelf_name(%Image{} = image), do: shelf_name(Image.logo?(image))

  @doc """
  The picture behind a proxy token, or `nil`. Narrowed to this kind, so a token
  from another kind's row cannot be served through the press proxy.
  """
  def get_by_token(token) when is_binary(token),
    do: Repo.get_by(Image, kind: @kind, token: token)

  def get_by_token(_token), do: nil

  @doc """
  Whether `viewer` may **write** `owner`'s press kit: upload into it, edit a
  caption, reorder a shelf, delete a picture.

  The one statement of that rule, and until #2085 there was none at all —
  `create/4` shipped in #2083 with no production caller and simply trusted
  whoever called it. Every write this module offers takes the viewer and asks it
  (`create/4`, `update/3`, `reorder/4`, `move/5`); `delete/1` is the exception
  and deliberately so, because the AI gate's refusal calls it too and has no
  viewer at all — the surface that offers a member a Remove button is what
  resolves the row.

  **Ask it per event, never once at mount.** A role that was withdrawn has to
  bite on the next action rather than the next login, which is the same reason
  `Vutuv.Organizations.acting_organization/2` re-reads it. #2087's page editor
  must gate its entry point on this and **not** on `Organizations.can_manage?/2`
  (the page's usual manage-menu gate): that one also counts the member who
  claimed the page, whether or not they still hold a role, and writing a press
  kit follows the roles.

  A member's press kit is theirs alone. A page's belongs to the people who may
  speak for it: an **owner** (who runs the page) or a **publisher** (who
  publishes in its name) — the pair #2087's editor is reachable by. Both come
  from one `Organizations.role_powers/2` read rather than two predicates, since
  this is asked on every write. An admin is deliberately **not** here, though
  `visible_to?/2` lets them look: moderating a picture is `Vutuv.Moderation`'s
  job and goes through the freeze, and no admin anywhere in vutuv edits a
  member's own data in their name.
  """
  def manageable_by?(%User{id: id}, %User{id: id}), do: true

  def manageable_by?(%Organization{} = organization, %User{} = viewer),
    do: organization |> Organizations.role_powers(viewer) |> manageable_by_powers?()

  def manageable_by?(_owner, _viewer), do: false

  @doc """
  The same rule, read off a `Vutuv.Organizations.role_powers/2` answer somebody
  already holds — for the page itself, which consolidated five permission reads
  into that one and must not grow a sixth to ask this.

  Public so the rule keeps one home: `manageable_by?/2` is this function plus
  the read.
  """
  def manageable_by_powers?(%{owner?: owner?, publisher?: publisher?}),
    do: owner? or publisher?

  @doc """
  Whether `viewer` may fetch this picture's bytes — the one statement of that
  rule, which the proxy and every surface #2086 and #2087 build ask.

  Three questions, and all three have to say yes. A frozen picture is nobody's,
  whoever is asking: a takedown has to read exactly like a picture that was never
  there. **The owner has to be visible too** — a suspended member and a page that
  is not on the public site take their press kit off the public site with them,
  which is one question for both sides because `Vutuv.Identity.hidden?/1` already
  answers it for a member and for a page. And the picture itself has to be
  released by the AI gate (`Vutuv.Images.servable?/1`, the one statement of that
  rule).

  Failing any of the last two still leaves the **privileged** viewer: the member
  whose kit it is, every member of a page's staff — a colleague has to be able to
  see what is being checked, and #2087 owns the surface that shows it to them —
  and an admin, the way they do for every other kind.
  """
  def visible_to?(%Image{kind: @kind, frozen_at: %NaiveDateTime{}}, _viewer), do: false

  def visible_to?(%Image{kind: @kind} = image, viewer) do
    case owner(image) do
      nil -> false
      owner -> public?(owner, image) or privileged?(owner, viewer)
    end
  end

  def visible_to?(_image, _viewer), do: false

  @doc """
  Whether the **pixelated stand-in** may be fetched — which is the mirror image
  of `visible_to?/2`: it answers for exactly the picture that one refuses
  because the AI gate has not released it yet.

  No viewer argument, deliberately. A press kit is a public section of a public
  profile, so there is no reader-specific question left once the owner is
  visible; what there is, is a *frozen* picture, and a takedown has to read like
  a picture that was never there — stand-in included.

  The cheap half is asked first on purpose: a released picture — every picture,
  a few seconds after it is uploaded — answers `false` here without touching the
  database, so the proxy's `or` costs one owner lookup rather than two.
  """
  def pixelated_visible?(%Image{kind: @kind, frozen_at: nil} = image),
    do: not ImageScans.released?(image.moderation) and owner_visible?(image)

  def pixelated_visible?(_image), do: false

  defp public?(owner, image), do: owner_visible?(owner) and Images.servable?(image)

  defp owner_visible?(%Image{} = image) do
    case owner(image) do
      nil -> false
      owner -> owner_visible?(owner)
    end
  end

  defp owner_visible?(owner), do: not Identity.hidden?(owner)

  defp privileged?(_owner, %User{admin?: true}), do: true
  defp privileged?(%User{id: id}, %User{id: id}), do: true

  defp privileged?(%Organization{} = organization, %User{} = viewer),
    do: Organizations.can_manage?(organization, viewer)

  defp privileged?(_owner, _viewer), do: false

  # The owner of a press picture: whichever half of the pair the row names.
  # Takes the preload when a caller remembered one and looks it up when nobody
  # did — half the callers hand over a bare row straight from a query, and an
  # answer that depends on whether somebody remembered a preload is not an
  # answer.
  defp owner(%Image{user: %User{} = user}), do: user
  defp owner(%Image{organization: %Organization{} = organization}), do: organization
  defp owner(%Image{user_id: id}) when is_binary(id), do: Repo.get(User, id)

  defp owner(%Image{organization_id: id}) when is_binary(id),
    do: Organizations.get_organization(id)

  defp owner(%Image{}), do: nil

  # The owner a whole shelf was read for, put on every row of it: the caller
  # already holds the record, so `owner/1` below never has to go and fetch it
  # fifteen times over.
  defp put_owner(%Image{} = image, %User{} = owner), do: %{image | user: owner}

  defp put_owner(%Image{} = image, %Organization{} = owner),
    do: %{image | organization: owner}

  ## URLs ---------------------------------------------------------------------

  @doc """
  The URL of a served version. One function owns this path: a hand-built copy at
  a call site is a place the next shelf, the next version name or a move of the
  proxy has to be remembered again.

  Under `/system/` rather than at a root word of its own. Profiles own the URL
  root, so a new root segment permanently burns a handle no member could claim
  again — the remote-media proxy set that pattern and this follows it, which is
  also why this kind needs no `Vutuv.Accounts.ReservedSlugs` entry.
  """
  def url(%Image{} = image, version), do: address(image, "#{version}.avif")

  @doc """
  What a page loads for this viewer (`VutuvWeb.UI.picture/1`), the twin of
  `Vutuv.Posts.PostImage.picture/1`: a photo's `feed` version, with the 640 px
  `lite` in its place while the viewer is in data-saving mode and that file is
  on disk. Asked of the disk rather than blind, because the proxy caches every
  version for a year as immutable and a lite URL answered with the feed bytes
  would stay the feed for that year.

  A **logo** has no such pair — nothing crops a wordmark and its two versions
  are 320 and 1200 px — so it loads its `thumb` for everybody.
  """
  def picture(%Image{logo: true} = image), do: %{src: url(image, "thumb"), lite: nil}

  def picture(%Image{} = image),
    do: LowBandwidth.picture(url(image, "feed"), fn -> lite_url(image) end)

  defp lite_url(%Image{} = image) do
    if PressKitStore.version_path(image.token, "lite"), do: url(image, "lite")
  end

  @doc """
  The version the lightbox opens: a photo's `xl` (2560 px), or `large` for a
  viewer in data-saving mode — on the phone screen such a viewer most likely
  holds, 1600 px is already more than the picture's own size. A logo's biggest
  is `large`, so that is what it opens at.
  """
  def lightbox_url(%Image{} = image) do
    cond do
      Image.logo?(image) -> url(image, "large")
      LowBandwidth.on?() -> url(image, "large")
      true -> url(image, "xl")
    end
  end

  @doc "The URL the file itself is handed over at: the cleaned photo, or a logo's vector."
  def download_url(%Image{} = image), do: address(image, "download.orig")

  @doc "The URL of a logo variant's PNG rendering, beside its vector."
  def png_download_url(%Image{} = image), do: address(image, "download.png")

  @doc """
  The URL of the pixelated stand-in, or `nil` when there is nothing standing in
  right now: the picture is released or frozen, the window has run out, the file
  was never written (an installation with the preview off) or the reader is in
  data-saving mode. A caller that gets `nil` draws the "being checked" tile.

  The window is measured from `inserted_at`, and this row **is** the upload —
  the one thing the mirrored kinds cannot say, since their `images` row is
  minted by the mirror and a backfilled one claims to be minutes old.

  Once per rendered picture, so a page drawing a whole shelf should hand over
  rows with `:user` or `:organization` preloaded — `owner/1` takes the preload
  when it is there and looks the owner up per picture when it is not.
  """
  def pixelated_url(%Image{} = image) do
    if pixelated_visible?(image) and
         Pixelation.stands_in?(PressKitStore.pixelated_path(image.token), image.inserted_at),
       do: address(image, Pixelation.filename())
  end

  # One owner of the proxy's path shape. Four addresses hang off it, and a
  # hand-built copy at a call site is a place the next one has to be remembered
  # again.
  defp address(%Image{token: token}, file), do: "/system/press_kit/#{token}/#{file}"

  @doc """
  Where this owner's press kit is published: `/ada.king/press` for a member,
  `/organizations/acme/press` for a page.

  For everything holding an owner rather than a route: the doc's canonical URL,
  the schema.org block, the card's footer link and the sitemap entry.

  **A page is addressed by its slug here, not by its root handle**, which is
  where this deviates from `Vutuv.Identity.path/1`. A page that claimed a root
  handle is canonical at `/acme`, but that handle dispatches the **bare**
  `/:slug` page alone (`VutuvWeb.Plug.UserResolveSlug`, `dispatch_organization:
  true` on that one route) — every sub-page of a page lives under
  `/organizations/:slug/`, exactly as its post permalinks do, and #2086 shipped
  `Identity.path/1 <> "/press"` here, which answered `/acme/press` for such a
  page and 404ed.
  """
  def page_path(%Organization{slug: slug}), do: "/organizations/#{slug}/press"
  def page_path(owner), do: Identity.path(owner) <> "/press"

  @doc """
  Where this kit is **edited**: `/settings/press` for a member (#2085), the
  page's own editor for a page (#2087).

  The second path this kind owns, and it needs one owner for the same reason the
  first does — four surfaces link to it (the section page's "Manage" bridge, the
  card's add tile, the page's manage menu and the editor's own trail), and a
  member's editor carries no slug at all while a page's does.
  """
  def editor_path(%Organization{slug: slug}), do: "/organizations/#{slug}/press/edit"
  def editor_path(%User{}), do: "/settings/press"

  @doc """
  The one sentence under which every press picture is offered.

  A property of the kit rather than of a page: the card and the section page
  show it, the lightbox states it as the picture's licence, the schema.org
  `usageInfo` carries it and the agent documents publish it as `rights` — five
  surfaces, one wording.
  """
  def rights_line, do: gettext("Free for editorial use with credit.")

  @doc """
  The name the downloaded file arrives under, e.g. `ada_king-press-1.jpg` or
  `acme-logo-2.svg` — a name that files itself on the recipient's disk, which
  `large.avif` never did.

  Built from the owner's handle rather than from the upload's own file name: the
  handle is what a journalist will look for months later, and it means this kind
  keeps no copy of a member-chosen string at all. Falls back to the shelf's own
  word for an owner that cannot be resolved, so a download never arrives as
  `-press-1.jpg`.
  """
  def download_name(%Image{} = image, ext) do
    shelf = if Image.logo?(image), do: "logo", else: "press"
    "#{image |> owner() |> owner_handle() || shelf}-#{shelf}-#{(image.position || 0) + 1}#{ext}"
  end

  # A page that has not claimed its root handle answers `nil` to
  # `Identity.handle/1`, and its slug is what `Organizations.canonical_path/1`
  # falls back to for exactly that case — a file called `acme-gmbh-press-1.jpg`
  # beats one called `press-1.jpg`.
  defp owner_handle(%Organization{} = organization),
    do: Identity.handle(organization) || organization.slug

  defp owner_handle(nil), do: nil
  defp owner_handle(owner), do: Identity.handle(owner)

  ## Writing ------------------------------------------------------------------

  @doc """
  Stores one press picture for `owner` (a member or a page) and records the row.

  `source` is a `{path, filename}` pair — the shape
  `consume_uploaded_entries/3` hands over, since #2085 uploads over the socket.
  `attrs` are the form's: `"logo"`, `"credit"`, `"caption"`, `"alt"` and the
  `"rights_confirmed"` tick, which is required and is what stamps
  `rights_confirmed_at`.

  **Nothing reaches the disk until the form is right.** The changeset is
  validated, the file measured against the cap and the shelf checked for room
  before a byte is written, so a refused upload leaves no directory behind; and
  a row that fails to insert afterwards takes its files with it, so the reverse
  cannot happen either.

  `{:error, changeset}` for a form problem, `{:error, :forbidden}` when this
  uploader may not write this owner's kit (`manageable_by?/2`), and
  `{:error, :too_large}`, `{:error, :too_many}` or `{:error, :invalid_file}`
  for the three the form cannot see. The authorization is asked **first**, so a
  refused upload never so much as measures the file.
  """
  def create(owner, %User{} = uploader, {path, filename}, attrs) do
    token = Uploads.gen_token()

    changeset =
      %Image{kind: @kind, token: token, logo: false}
      |> struct!(owner_columns(owner, uploader))
      |> Image.press_kit_changeset(attrs)

    logo? = changeset |> Ecto.Changeset.apply_changes() |> Image.logo?()

    with :ok <- authorize(owner, uploader),
         :ok <- validate_form(changeset),
         :ok <- validate_size(path),
         {:ok, position} <- take_slot(owner, logo?),
         {:ok, meta} <- PressKitStore.store(path, filename, token, logo?) do
      insert(changeset, position, meta, token)
    end
  end

  @doc """
  The page's own logo file, when it is one the logo shelf could take as a
  variant: the absolute path of the stored original, or `nil` (#2087).

  **A vector only, deliberately.** A press logo is offered for print, and what a
  page uploaded as a raster is already the screen-sized copy
  `Vutuv.OrganizationImageStore` derived from it — handing a journalist a 512 px
  PNG under the word "logo" is worse than handing them nothing, and it is what
  the page's own tile already shows. A vector is the one case where the file the
  page uploaded **is** the printable one, which is why #2082 asked for the
  one-click offer on exactly that case.

  It asks the disk rather than the row's `content_type`, because the disk is
  what `adopt_page_logo/3` will copy: an installation restored from a snapshot
  carries no `originals/` tree, and a button offering a file that is not there
  would fail on the press instead of never appearing.
  """
  def page_logo_source(%Organization{logo: token}) when is_binary(token) do
    path = OrganizationImageStore.original_path(token)

    if path && Path.extname(path) == ".svg", do: path
  end

  def page_logo_source(_owner), do: nil

  @doc """
  Copies that logo onto the page's logo shelf as one more variant — the
  one-click adoption, which is `create/4` with the page's own file standing in
  for the upload.

  Through `create/4` and nothing else, so it inherits every rule a picked file
  meets: the authorization, the shelf cap, the whitelist, the rights stamp and
  the AI scan. `attrs` are the add form's, the rights tick included — the page
  holds this file, but releasing it for editorial use with a credit is still a
  decision somebody makes rather than one adoption may imply.
  """
  def adopt_page_logo(%Organization{} = organization, %User{} = viewer, attrs) do
    case page_logo_source(organization) do
      nil ->
        {:error, :invalid_file}

      path ->
        create(organization, viewer, {path, Path.basename(path)}, Map.put(attrs, "logo", true))
    end
  end

  # A member's kit has no page logo to adopt, and the editor offers the button
  # on a page alone — but the event arrives from a client, so the clause that
  # cannot happen answers rather than raising.
  def adopt_page_logo(_owner, _viewer, _attrs), do: {:error, :forbidden}

  @doc """
  Edits one stored picture's label, credit and caption — the only three columns
  a form may write once the file is on disk (`Image.press_kit_update_changeset/2`
  says which are missing and why).

  Takes the row rather than an owner and an id, because the surface has already
  resolved it out of that owner's own shelves, which is a stronger answer than a
  predicate — a foreign id is not refused, it is never found. `viewer` is asked
  all the same, so the rule holds for a surface that resolves rows some other
  way.
  """
  def update(%Image{kind: @kind} = image, %User{} = viewer, attrs) do
    with :ok <- authorize(owner(image), viewer) do
      image
      |> Image.press_kit_update_changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Persists a drag-and-drop order for one shelf as positions **0..n-1**, over
  exactly the pictures that owner has on it.

  Not `Vutuv.Ordering.reorder/3`, which is the profile sections' own face on the
  same tool: that one scopes to a schema's `user_id`, and a press picture's
  owner is a member **or** a page, on one of two shelves. The shared halves are
  `Ordering.arrange/2` (reading an untrusted payload), `Ordering.ordered_ids/1`
  and `Ordering.persist_order/3`, which takes the scope as a query and the first
  position as an argument — 0 here, because `create/4` has handed out `count` as
  the next position since #2083 and `download_name/2` reads `position + 1`, so
  renumbering from 1 would rename the hero's file.
  """
  def reorder(owner, %User{} = viewer, logo?, submitted_ids)
      when is_boolean(logo?) and is_list(submitted_ids) do
    with :ok <- authorize(owner, viewer) do
      ids = owner |> shelf(logo?) |> Ordering.ordered_ids()
      persist_order(owner, logo?, Ordering.arrange(ids, submitted_ids))
    end
  end

  @doc """
  Nudges one picture a single step along its shelf — the arrow buttons, which
  are the reorder path on a phone, where no native drag event exists. An
  out-of-range move is a no-op, as is an id that is not on this shelf.
  """
  def move(owner, %User{} = viewer, logo?, id, direction)
      when is_boolean(logo?) and direction in [:up, :down] do
    with :ok <- authorize(owner, viewer) do
      ids = owner |> shelf(logo?) |> Ordering.ordered_ids()
      persist_order(owner, logo?, Ordering.swap(ids, id, direction))
    end
  end

  @doc """
  The credit to offer the next upload, read off a shelf the caller already
  holds — the last picture on it that carries one, or `nil`. A photographer's
  line is set once and then holds for every picture of that session.

  Takes the list rather than the owner so the page that has just loaded both
  shelves pays no second query for it; per shelf because a photo's credit names
  whoever took it and a logo's whoever drew it, and offering one as the other is
  worse than offering nothing.
  """
  def last_credit(images) when is_list(images) do
    images
    |> Enum.reject(&(&1.credit in [nil, ""]))
    |> List.last()
    |> case do
      nil -> nil
      image -> image.credit
    end
  end

  @doc """
  What the editor's credit field is **offered** ready-filled with: the last
  picture on that shelf where there is one (`last_credit/1`), and the owner's
  own name where there is not.

  The fallback is the whole point. A press picture with no credit is one a
  journalist may not print, and until now a first-time member met an empty field
  — the shelf they were filling had nothing to copy a line from. The name is
  right far more often than blank is: most members are photographed by somebody
  they can name, and the ones who took the picture themselves are named
  correctly by it.

  The **owner's** name, never the uploader's: a page's press kit belongs to the
  page, and the colleague who uploads for it is not who the credit names.

  A default, not a value. It is rendered into an ordinary editable input and
  nothing writes it at save time, so a member who clears the field stores an
  empty credit — the field says what will be stored, which is the only way a
  prefill can be honest.
  """
  def credit_default(owner, images) when is_list(images),
    do: last_credit(images) || Identity.display_name(owner)

  @doc """
  Releases a press picture the AI gate cleared, and answers `:stale` when the row
  is no longer the one that was waiting (deleted meanwhile, or already settled by
  a verdict that got there first).

  Here rather than in `Vutuv.Moderation.ImageSubjects` so that the shared
  `images` table keeps one writer per kind — the refusal beside it already goes
  through `delete/1`.
  """
  def release(image_id) when is_binary(image_id) do
    from(i in Image,
      where: i.id == ^image_id and i.kind == ^@kind and i.moderation == "pending"
    )
    |> Repo.update_all(set: [moderation: "approved", updated_at: NaiveDateTime.utc_now(:second)])
    |> case do
      {1, _} -> :ok
      _none -> :stale
    end
  end

  @doc """
  Removes a press picture: the row first, then every file, then any takedown
  hold. That order is the one an interruption can survive — it leaves files
  nothing points at rather than a row naming files that are gone.

  One path with the upheld copyright case, not two: `Vutuv.Images.purge/1`
  gates on the same `@takedown` entry that lets a case name this kind at all,
  and while the kind had no entry (#2083) this had to be its own copy. The
  refused AI verdict takes it too, so "the files are gone" is one function.
  """
  def delete(%Image{kind: @kind} = image), do: Images.purge(image)

  @doc """
  Every press-kit token this **owner** holds — what `Vutuv.Accounts.delete_user/1`
  and `Vutuv.Organizations.delete_organization/1` collect before the delete,
  because the row cascades and the files on disk do not.

  For a member that is deliberately not the pictures they uploaded *for a page*:
  those belong to the page and stay, which is the whole reason the uploader rides
  in a column of its own.
  """
  def tokens(owner), do: Repo.all(from(i in owned(owner), select: i.token))

  ## ---------------------------------------------------------------------------

  # One shelf of one owner, as a query — the scope everything about a shelf is
  # written against: the listing, the ids a reorder rearranges, and the rows a
  # renumber may touch.
  defp shelf(owner, logo?), do: from(i in owned(owner), where: i.logo == ^logo?)

  # "The AI gate let this out and no copyright case took it away", in SQL. One
  # spelling, so `public_query/0` and `published_shelves/1` cannot drift.
  defp released(query) do
    from(i in query,
      where: is_nil(i.frozen_at) and (is_nil(i.moderation) or i.moderation == "approved")
    )
  end

  # One list of rows as the two shelves a surface draws. `split_with/2` puts the
  # matching side first, and the matching side here is the logos.
  defp split(images) do
    {logos, photos} = Enum.split_with(images, &Image.logo?/1)
    %{photos: photos, logos: logos}
  end

  # `position` is what the owner arranged; the id breaks a tie, and since ids are
  # UUID v7 that is upload order rather than a coin toss.
  defp shelf_rows(owner, logo?),
    do: owner |> shelf(logo?) |> Ordering.by_position() |> Repo.all()

  # `party_is/2` rather than a clause per owner kind: it is the one SQL spelling
  # of "this row's member-or-page pair names this party" (#1416), so a call site
  # cannot forget the side it did not think of.
  defp owned(party), do: from(i in Image, where: i.kind == @kind and party_is(i, party))

  # A member owns their own press kit outright, so `uploader_user_id` stays
  # empty; a page owns its own and the member who uploaded it is only recorded
  # — `images.user_id` cascades, so naming the uploader there would delete a
  # page's press photo the day that colleague closes their account.
  defp owner_columns(%User{} = owner, _uploader), do: %{user_id: Query.user_side(owner)}

  defp owner_columns(%Organization{} = owner, %User{id: uploader_id}),
    do: %{organization_id: Query.organization_side(owner), uploader_user_id: uploader_id}

  # Who a rejection is told about. A member owns their own kit; a page's row
  # leaves `user_id` empty by constraint, so the scan takes the **uploader** —
  # the colleague whose file was refused, and the only member the row names at
  # all. It is what an organization logo's scan already does.
  defp scan_owner_id(%Image{user_id: id}) when is_binary(id), do: id
  defp scan_owner_id(%Image{uploader_user_id: id}), do: id

  defp authorize(owner, uploader),
    do: if(manageable_by?(owner, uploader), do: :ok, else: {:error, :forbidden})

  defp validate_form(changeset), do: if(changeset.valid?, do: :ok, else: {:error, changeset})

  # Positions 0..n-1, each write scoped to the owner **and** the shelf, so a
  # stray id cannot renumber a picture that is not on this list.
  defp persist_order(owner, logo?, ordered_ids),
    do: Ordering.persist_order(shelf(owner, logo?), ordered_ids, 0)

  defp validate_size(path) do
    if File.stat!(path).size > max_filesize(), do: {:error, :too_large}, else: :ok
  end

  # The room on the shelf and the position the new picture takes are the same
  # count, so they are one query rather than two. Two uploads racing can land on
  # the same position; #2085's editor is what reorders them, and the id
  # tiebreaker in `shelf/2` keeps the order stable meanwhile.
  defp take_slot(owner, logo?) do
    used = count(owner, logo?)
    cap = if logo?, do: max_logos(), else: max_photos()

    if used < cap, do: {:ok, used}, else: {:error, :too_many}
  end

  defp insert(changeset, position, meta, token) do
    changeset
    |> Ecto.Changeset.change(%{
      position: position,
      moderation: ImageScans.initial_state(),
      width: meta.width,
      height: meta.height,
      content_type: meta.content_type,
      size_bytes: meta.size_bytes
    })
    |> Repo.insert()
    |> case do
      {:ok, image} ->
        ImageScans.enqueue(@kind, image.id, scan_owner_id(image))
        {:ok, image}

      {:error, changeset} ->
        # The files are already on disk by now, and nothing points at them.
        PressKitStore.delete(token)
        {:error, changeset}
    end
  end
end
