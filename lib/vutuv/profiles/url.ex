defmodule Vutuv.Profiles.Url do
  @moduledoc false

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [validate_url: 1]

  schema "urls" do
    field(:value, :string)
    field(:description, :string)
    field(:screenshot, :string)
    field(:broken?, :boolean)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

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
    |> validate_length(:description, max: 45)
    |> ensure_http_prefix
    |> validate_url
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
