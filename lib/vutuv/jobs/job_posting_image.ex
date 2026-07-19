defmodule Vutuv.Jobs.JobPostingImage do
  @moduledoc """
  An image belonging to a job posting (or, while composing, to a user) — the
  post-image pattern 1:1 (`Vutuv.Posts.PostImage`).

  Images are uploaded eagerly as a gallery, so `job_posting_id` stays `nil`
  until the posting is saved; unattached rows are swept. Derived versions
  (`thumb`/`feed`/`large`) are metadata-stripped AVIF; the original stays
  private. Serving always goes through the authorizing proxy
  (`/job_posting_images/:token/:version`) — `token` is the lookup key and
  on-disk directory name, never the row id.
  """

  use VutuvWeb, :model

  alias Vutuv.Uploads.Spec

  @versions ~w(thumb feed large)

  schema "job_posting_images" do
    belongs_to(:job_posting, Vutuv.Jobs.JobPosting)
    belongs_to(:user, Vutuv.Accounts.User)

    field(:token, :string)
    field(:alt, :string, default: "")
    field(:position, :integer, default: 0)
    field(:width, :integer)
    field(:height, :integer)
    field(:content_type, :string)
    field(:size_bytes, :integer)

    # AI image moderation state (Vutuv.Moderation.ImageScans). DB default is
    # "pending", so an image is invisible-to-others until released.
    field(:moderation, :string, default: "pending")

    timestamps()
  end

  def versions, do: @versions

  def alt_changeset(image, params) do
    image
    |> cast(params, [:alt])
    |> update_change(:alt, &String.trim/1)
    |> validate_length(:alt, max: 255)
  end

  @doc "A fresh unguessable URL token (~128 bits, URL-safe)."
  def gen_token do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc "Root-relative proxy URL for a version of this image."
  def url(%__MODULE__{token: token}, version) when version in @versions do
    "#{token_prefix(token)}#{version}#{Spec.served_ext()}"
  end

  defp token_prefix(token), do: "/job_posting_images/#{token}/"
end
