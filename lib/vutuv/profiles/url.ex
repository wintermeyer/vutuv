defmodule Vutuv.Profiles.Url do
  @moduledoc false

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [validate_url: 1]

  schema "urls" do
    field(:value, :string)
    field(:description, :string)
    field(:screenshot, :string)
    field(:broken, :boolean)

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
    |> cast(params, [:value, :description, :broken])
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

    if url && !String.contains?(url, ["http://", "https://"]) do
      put_change(changeset, :value, "http://#{url}")
    else
      changeset
    end
  end
end
