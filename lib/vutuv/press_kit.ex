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

  ## Born pending

  A fresh row starts at `Vutuv.Moderation.ImageScans.initial_state/0`, so on an
  installation with the AI gate on it is `"pending"` and `visible_to?/2` shows
  it to its owner alone until a verdict releases it. Nothing here enqueues that
  scan yet — #2084 wires the scan, the pixelated stand-in and the takedown, and
  `Vutuv.Images.takedown_ready?/1` answers false for this kind until it does.
  """

  import Ecto.Query, warn: false
  import Vutuv.Identity.Query, only: [party_is: 2]

  alias Vutuv.Accounts.User
  alias Vutuv.Identity
  alias Vutuv.Identity.Query
  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.Moderation.ImageScans
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
  def photos(owner), do: shelf(owner, false)

  @doc "The owner's logo variants, in the order they are shown."
  def logos(owner), do: shelf(owner, true)

  @doc "How many pictures the owner has on that shelf."
  def count(owner, logo?) when is_boolean(logo?) do
    Repo.aggregate(from(i in owned(owner), where: i.logo == ^logo?), :count)
  end

  @doc """
  The picture behind a proxy token, or `nil`. Narrowed to this kind, so a token
  from another kind's row cannot be served through the press proxy.
  """
  def get_by_token(token) when is_binary(token),
    do: Repo.get_by(Image, kind: @kind, token: token)

  def get_by_token(_token), do: nil

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

  defp public?(owner, image), do: not Identity.hidden?(owner) and Images.servable?(image)

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
  def url(%Image{token: token}, version), do: "/system/press_kit/#{token}/#{version}.avif"

  @doc "The URL the file itself is handed over at: the cleaned photo, or a logo's vector."
  def download_url(%Image{token: token}), do: "/system/press_kit/#{token}/download.orig"

  @doc "The URL of a logo variant's PNG rendering, beside its vector."
  def png_download_url(%Image{token: token}), do: "/system/press_kit/#{token}/download.png"

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

  `{:error, changeset}` for a form problem, `{:error, :too_large}`,
  `{:error, :too_many}` or `{:error, :invalid_file}` for the three the form
  cannot see.
  """
  def create(owner, %User{} = uploader, {path, filename}, attrs) do
    token = Uploads.gen_token()

    changeset =
      %Image{kind: @kind, token: token, logo: false}
      |> struct!(owner_columns(owner, uploader))
      |> Image.press_kit_changeset(attrs)

    logo? = changeset |> Ecto.Changeset.apply_changes() |> Image.logo?()

    with :ok <- validate_form(changeset),
         :ok <- validate_size(path),
         {:ok, position} <- take_slot(owner, logo?),
         {:ok, meta} <- PressKitStore.store(path, filename, token, logo?) do
      insert(changeset, position, meta, token)
    end
  end

  @doc """
  Removes a press picture: the row first, then every file. That order is the one
  an interruption can survive — it leaves files nothing points at rather than a
  row naming files that are gone.
  """
  def delete(%Image{kind: @kind} = image) do
    Repo.delete_all(from(i in Image, where: i.id == ^image.id))
    PressKitStore.delete(image.token)
    :ok
  end

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

  defp shelf(owner, logo?) do
    from(i in owned(owner),
      where: i.logo == ^logo?,
      # `position` is what the owner arranged; the id breaks a tie, and since
      # ids are UUID v7 that is upload order rather than a coin toss.
      order_by: [asc: i.position, asc: i.id]
    )
    |> Repo.all()
  end

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

  defp validate_form(changeset), do: if(changeset.valid?, do: :ok, else: {:error, changeset})

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
        {:ok, image}

      {:error, changeset} ->
        # The files are already on disk by now, and nothing points at them.
        PressKitStore.delete(token)
        {:error, changeset}
    end
  end
end
