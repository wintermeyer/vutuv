defmodule Vutuv.Profiles.Url do
  @moduledoc false

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [validate_url: 1]

  schema "urls" do
    field(:value, :string)
    field(:description, :string)
    field(:screenshot, :string)
    field(:broken?, :boolean)
    # The owner's chosen display order. Set programmatically (on create and via
    # the reorder/move actions), never cast from user params. NULLs sort last so
    # legacy rows fall back to creation order until reordered. See Vutuv.Ordering.
    field(:position, :integer)

    # "This link is my webpage" verification (Vutuv.Profiles.LinkVerification).
    # All set programmatically, never cast from user params: the method that
    # last proved it (rel_me / dns / well_known), the token the DNS / well-known
    # proofs publish (rel=me needs none), and the re-check timestamps.
    field(:verification_method, :string)
    field(:verification_token, :string)
    field(:verified_at, :naive_datetime)
    field(:last_checked_at, :naive_datetime)
    field(:grace_deadline_at, :naive_datetime)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @methods ~w(rel_me dns well_known)

  @doc "The verification proof methods a member may use for a link."
  def methods, do: @methods

  @doc "Whether this link has proved it is the member's own webpage."
  def verified?(%__MODULE__{verified_at: at}), do: not is_nil(at)

  @doc "Links in the owner's chosen order (see `Vutuv.Ordering`)."
  def ordered(query \\ __MODULE__), do: Vutuv.Ordering.by_position(query)

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:value, :description, :broken?])
    |> put_screenshot(params)
    |> validate_required([:value])
    # varchar(255) column: an overlong URL must fail as a changeset error,
    # never as a raised Postgres 22001 (which 500ed the LinkedIn import).
    |> validate_length(:value, max: 255)
    |> validate_length(:description, max: 45)
    |> ensure_http_prefix
    |> validate_url
    |> reset_verification_on_value_change()
  end

  # Editing the link to a different URL invalidates any existing proof (the
  # member could otherwise verify example.com and then point the row at
  # evil.com while keeping the mark), so clear the verified state. The token is
  # kept — it is a host-independent random string the member can re-publish.
  defp reset_verification_on_value_change(changeset) do
    if get_change(changeset, :value) && get_field(changeset, :verified_at) do
      changeset
      |> put_change(:verification_method, nil)
      |> put_change(:verified_at, nil)
      |> put_change(:last_checked_at, nil)
      |> put_change(:grace_deadline_at, nil)
    else
      changeset
    end
  end

  @doc """
  Records verification state (set programmatically by
  `Vutuv.Profiles.LinkVerification`, never from user params): the proof
  `verification_method`, the DNS / well-known `verification_token`, and the
  re-check timestamps.
  """
  def verification_changeset(model, attrs) do
    model
    |> cast(attrs, [
      :verification_method,
      :verification_token,
      :verified_at,
      :last_checked_at,
      :grace_deadline_at
    ])
    |> validate_inclusion(:verification_method, @methods)
    # varchar(255) column: an oversized token must fail as a changeset error,
    # never as a raised Postgres 22001. Tokens are ~32 chars, so this can only
    # trip on a bug, but the column-limit rule applies to every :string field.
    |> validate_length(:verification_token, max: 255)
  end

  # Screenshots are generated server-side (headless Chromium) and stored via
  # the uploader, so the field is set programmatically rather than cast from
  # params.
  defp put_screenshot(changeset, %{"screenshot" => %Plug.Upload{} = upload}),
    do: store_screenshot(changeset, upload)

  defp put_screenshot(changeset, %{screenshot: %Plug.Upload{} = upload}),
    do: store_screenshot(changeset, upload)

  defp put_screenshot(changeset, _params), do: changeset

  defp store_screenshot(changeset, upload) do
    case Vutuv.Screenshot.store({upload, Ecto.Changeset.apply_changes(changeset)}) do
      {:ok, file_name} -> put_change(changeset, :screenshot, file_name)
      {:error, _reason} -> add_error(changeset, :screenshot, "is not a valid image")
    end
  end

  defp ensure_http_prefix(changeset) do
    url = get_change(changeset, :value)

    # Prepend http:// unless the value already carries an http(s) scheme.
    # Gating on "scheme is not http/https" (rather than "scheme is nil") is
    # deliberate: URI.parse reads a bare "example.com:8080" as scheme
    # "example.com", so a nil check would leave a legitimate host:port
    # un-prefixed and validate_url would then reject it. A genuinely dangerous
    # scheme (javascript:/data:) gets prefixed to a broken http:// host that
    # validate_url rejects anyway, so nothing unsafe survives.
    if url && URI.parse(url).scheme not in ["http", "https"] do
      put_change(changeset, :value, "http://#{url}")
    else
      changeset
    end
  end
end
