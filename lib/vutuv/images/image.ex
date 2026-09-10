defmodule Vutuv.Images.Image do
  @moduledoc """
  One stored picture, whatever kind it is: what it is (`kind`), whose it is,
  the unguessable handle it can be named by from outside (`token`), the three
  columns describing the stored file, the AI gate's verdict, and whether a
  copyright case has taken it offline (`frozen_at`, written by #2012).

  Why this table exists and what the member row still holds beside it is in
  `docs/architecture/images.md`; `Vutuv.Images` is the context.
  """

  use VutuvWeb, :model

  alias Vutuv.Uploads

  schema "images" do
    field(:kind, :string)
    belongs_to(:user, Vutuv.Accounts.User)

    # The parent a gallery picture belongs to. Nil for a profile picture, and
    # nil for a picture whose parent has not been saved yet — a posting image
    # in the job editor, a photo in the composer, a description picture in the
    # organization editor. One column per parent kind, as #2013's migration
    # asked for.
    belongs_to(:job_posting, Vutuv.Jobs.JobPosting)
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:organization, Vutuv.Organizations.Organization)

    # The review a fetched book cover belongs to (#2055). Unlike the three
    # above this one is also the **join key**: a review's cover is columns on
    # the review row with no token of its own, so there is nothing else to
    # match the two sides on. Exactly one cover per review, by unique index.
    belongs_to(:post_review, Vutuv.Posts.PostReview)

    # The file a rendered preview page belongs to (#2105). Like the review
    # above it is the join key as well as the parent: a page is named by its
    # file and its `position`, and the two together are unique.
    belongs_to(:attachment, Vutuv.Attachments.Attachment)

    # Who uploaded an organization image — **not** who owns it (#2053). The
    # page owns its logo, which is why `organization_images.user_id` is
    # `ON DELETE SET NULL` and this column copies that: a page keeps its
    # picture when the member who uploaded it closes their account, while
    # `user_id` above cascades and is empty for this kind by check constraint.
    belongs_to(:uploader, Vutuv.Accounts.User, foreign_key: :uploader_user_id)

    field(:token, :string)

    # The upload's own file name, the content fingerprint baked into the
    # served file name (`<handle>-<version>-<fingerprint>.avif`) and the
    # member's crop rectangle — the three the member row holds today.
    field(:file, :string)
    field(:fingerprint, :string)
    field(:crop, :string)

    # `Vutuv.Moderation.ImageScans`: nil = grandfathered, "pending" = the
    # files wait in quarantine, "approved" = released.
    field(:moderation, :string)

    # Set by a copyright freeze (#2012). A freeze moves files, never deletes.
    field(:frozen_at, :naive_datetime)

    # What a gallery row holds besides the above, copied column for column from
    # the table it mirrors — `job_posting_images`, `post_images` and
    # `organization_images` all carry these six under the same names. Nil for a
    # profile picture, which has none of them.
    field(:alt, :string)
    field(:position, :integer)
    field(:width, :integer)
    field(:height, :integer)
    field(:content_type, :string)
    field(:size_bytes, :integer)

    # Picture attributes the post photo brought in (#2052) and the kinds that
    # have them share, the way `crop` above is shared: the caption shown under
    # the picture, the whitelisted camera facts `Vutuv.Uploads.Exif` parses at
    # upload, the fact (never the coordinates) that the upload carried a
    # location, and the author's three per-photo switches. Nil on a row of a
    # kind that has no such thing.
    field(:caption, :string)
    field(:camera, :string)
    field(:lens, :string)
    field(:focal_length, :string)
    field(:aperture, :string)
    field(:shutter, :string)
    field(:iso, :integer)
    field(:taken_at, :naive_datetime)
    field(:has_gps, :boolean)
    field(:show_camera_info, :boolean)
    field(:download_original, :boolean)
    field(:download_exact, :boolean)

    # What a press-kit picture adds (#2083, `Vutuv.PressKit`): the credit line
    # shown beside it, when its uploader confirmed they hold the rights and
    # release it for editorial use, and which of the two shelves it is on —
    # `false` a press photo, `true` a logo variant. Nil on every other kind,
    # which has no opinion about any of the three; two check constraints make
    # the last two NOT NULL for this kind alone.
    field(:credit, :string)
    field(:rights_confirmed_at, :naive_datetime)
    field(:logo, :boolean)

    # The rights confirmation as the uploader gives it — a tick, not a
    # timestamp. `press_kit_changeset/2` stamps `rights_confirmed_at` from it,
    # the way `Vutuv.Profiles.Qualification` stamps `document_consented_at` from
    # `document_consent`: the moment is ours to record, never the form's to
    # send.
    field(:rights_confirmed, :boolean, virtual: true)

    timestamps()
  end

  @doc """
  Only the four columns describing the stored file are cast. `kind`, `user_id`,
  `token` and `frozen_at` are set programmatically — on the struct by
  `Vutuv.Images.put_profile_image/3`, in an `update_all` by
  `Vutuv.Images.freeze/1` — and casting them would mean a report form standing
  next to this code could hand over a `frozen_at` or somebody else's `user_id`.

  Of the four, `file` is the only one worth a length validation: it is the
  upload's own name, which a member chooses, and an over-long one would
  otherwise raise Postgres 22001 on a path no form guards. The others are
  derived here and bounded by construction, in varchar(255) columns.

  The bound comes from `Vutuv.Uploads.max_stored_file_name/0`, which is also
  what the uploader cuts the name to, so this validation and the cut guarding
  the same write cannot drift apart. It is the second line, not the first: the
  cut is what a member actually meets (issue #2025).
  """
  def changeset(image, attrs) do
    image
    |> cast(attrs, [:file, :fingerprint, :crop, :moderation])
    |> validate_required([:kind, :token])
    |> validate_length(:file, max: Uploads.max_stored_file_name())
    |> unique_constraint(:token)
    |> unique_constraint(:kind, name: :images_member_profile_kind_index)
    |> check_constraint(:user_id, name: :images_profile_kind_has_owner)
    |> foreign_key_constraint(:user_id)
  end

  # How long a press caption may be. **Deliberately not**
  # `Vutuv.Posts.PostImage.max_caption_length/0` (1,000), although both write the
  # same `:text` column: a post photo's caption is a line under a picture in a
  # timeline, while a press caption is what a journalist reads instead of asking
  # — who took it, where, at what event, what may be cropped. This is the
  # work-experience description's cap, which is the field issue #2083 names as
  # its model. Two caps on one column is fine as long as each surface's owns
  # one; two spellings of the same cap would not be.
  @press_caption_length 10_000

  @doc "Whether this row is a press **logo variant** rather than a press photo."
  def logo?(%__MODULE__{logo: logo}), do: logo == true

  @doc "The longest press caption `press_kit_changeset/2` accepts."
  def max_press_caption_length, do: @press_caption_length

  @doc """
  A press photo or a logo variant (#2083). The one kind whose row is written
  here directly rather than copied from a table of its own, so this is the only
  validation standing between a member's form and the column.

  `kind`, `token`, the owner columns and `position` are set by
  `Vutuv.PressKit` and deliberately not cast: a form that could name its own
  `user_id` could hang a picture on somebody else's profile, and one that could
  name its own `position` could bump another member's hero out of first place.

  **The rights confirmation is the gate, not a field.** Nothing may be stored
  without it — it is what allows the file to be handed out at all — so the
  virtual tick is required to be `true` and the timestamp is stamped here.
  Re-editing a caption later keeps the original stamp: `rights_confirmed_at`
  records when the release was given, not when the row was last touched.

  The three length bounds are the columns': `credit` and `alt` are varchar(255),
  and an over-long value raises Postgres 22001 rather than a form error, since
  Ecto does not enforce a column limit. `file` is not among them because it is
  not cast either — a press picture keeps no copy of the upload's own name at
  all, its download being named after the owner's handle
  (`Vutuv.PressKit.download_name/2`), so the column stays NULL for this kind.
  """
  def press_kit_changeset(image, attrs) do
    image
    |> cast(attrs, [:alt, :caption, :credit, :logo, :rights_confirmed])
    |> validate_required([:kind, :token, :logo])
    |> press_bounds()
    |> confirm_rights()
    |> unique_constraint(:token)
    |> check_constraint(:user_id, name: :images_press_kit_has_one_owner)
    |> check_constraint(:logo, name: :images_press_kit_declared)
  end

  @doc """
  The **edit** of a press picture that is already stored (#2085): its label, its
  credit and its caption, and nothing else.

  Three columns are deliberately missing from the cast, and each absence is a
  rule rather than an oversight. `logo` would move the picture between the two
  shelves, past the cap the other one is counted against and past the format
  whitelist it was stored under — a JPEG would arrive on the logo shelf, where
  every reader expects a vector or a PNG. `rights_confirmed` would let an edit
  re-give a release that was already given; the timestamp records **when the
  file was released**, not when its caption was last touched, so
  `confirm_rights/1` below keeps the original stamp on this path. And
  `position` is the editor's to write through `Vutuv.PressKit.reorder/4`, never
  a form's — a form that could name its own would bump another picture out of
  the hero slot.

  The three bounds are the columns' own, exactly as on the create path: Ecto
  does not enforce a column limit, so an over-long value would otherwise raise
  Postgres 22001 — here on a plain Save, which is a 500 on a form submit.
  """
  def press_kit_update_changeset(image, attrs) do
    image
    |> cast(attrs, [:alt, :caption, :credit])
    |> press_bounds()
    |> confirm_rights()
  end

  # The three columns' own limits, in one place for both press changesets: Ecto
  # does not enforce a column limit, so an over-long value raises Postgres 22001
  # rather than a form error, and two copies of the bound would mean one of them
  # keeps a widened column's old number.
  defp press_bounds(changeset) do
    changeset
    |> validate_length(:credit, max: 255)
    |> validate_length(:alt, max: 255)
    |> validate_length(:caption, max: @press_caption_length)
  end

  # Two branches, and the order matters. A **fresh** row is stored only against
  # the tick, which is what allows the file to be handed out at all — and it
  # reaches the third branch rather than the second because `PressKit.create/4`
  # starts from a blank `%Image{}`, which has no stamp to keep. An **edit** of a
  # row that already carries one keeps it: the release was given once, at
  # upload, and re-stamping it on every caption fix would erase the one fact the
  # column exists to record.
  defp confirm_rights(changeset) do
    cond do
      get_change(changeset, :rights_confirmed) == true ->
        put_change(changeset, :rights_confirmed_at, NaiveDateTime.utc_now(:second))

      not is_nil(get_field(changeset, :rights_confirmed_at)) ->
        changeset

      true ->
        add_error(changeset, :rights_confirmed, "must be confirmed")
    end
  end
end
