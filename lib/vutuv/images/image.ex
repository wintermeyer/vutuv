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

  schema "images" do
    field(:kind, :string)
    belongs_to(:user, Vutuv.Accounts.User)

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

    timestamps()
  end

  @doc """
  Every field here is written by the pipeline that stored the file, never by a
  form, so the only length worth validating is `file`: it is the upload's own
  name, which a member chooses, and an over-long one would otherwise raise
  Postgres 22001 on a path no form guards. The rest are minted here and bounded
  by construction, in varchar(255) columns.
  """
  def changeset(image, attrs) do
    image
    |> cast(attrs, [:kind, :user_id, :token, :file, :fingerprint, :crop, :moderation, :frozen_at])
    |> validate_required([:kind, :token])
    |> validate_length(:file, max: 255)
    |> unique_constraint(:token)
    |> unique_constraint(:kind, name: :images_member_profile_kind_index)
    |> check_constraint(:user_id, name: :images_profile_kind_has_owner)
    |> foreign_key_constraint(:user_id)
  end
end
