defmodule Vutuv.Posts.PostImage do
  @moduledoc """
  An image belonging to a post (or, while composing, to a user).

  Images are uploaded eagerly — the composer needs a URL before the post
  exists so the author can reference the image inline (`![](url)`) — so
  `post_id` stays `nil` until the post is submitted. Unattached rows older
  than a day are swept (`Vutuv.Posts.sweep_pending_images/0`).

  All derived versions (`thumb`/`feed`/`large`) are metadata-stripped WebP;
  the original keeps its metadata and is never served. Serving always goes
  through the authorizing proxy (`/post_images/:token/:version`) — `token`
  is the lookup key and on-disk directory name, never the row id.
  """

  use VutuvWeb, :model

  @versions ~w(thumb feed large)

  schema "post_images" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:user, Vutuv.Accounts.User)

    field(:token, :string)
    field(:alt, :string, default: "")
    field(:position, :integer, default: 0)
    field(:width, :integer)
    field(:height, :integer)
    field(:content_type, :string)
    field(:size_bytes, :integer)

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
    "/post_images/#{token}/#{version}.webp"
  end

  @doc "URLs for every served version as a `%{version => url}` map."
  def urls(%__MODULE__{} = image) do
    %{thumb: url(image, "thumb"), feed: url(image, "feed"), large: url(image, "large")}
  end
end
