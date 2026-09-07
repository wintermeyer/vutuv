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
    # in the job editor, a photo in the composer. One column per parent kind,
    # as #2013's migration asked for; the organization adds hers when she moves
    # (#2053).
    belongs_to(:job_posting, Vutuv.Jobs.JobPosting)
    belongs_to(:post, Vutuv.Posts.Post)

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
    # the table it mirrors (`job_posting_images` and `post_images` today;
    # `organization_images` carries the same six under the same names). Nil for
    # a profile picture, which has none of them.
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
end
