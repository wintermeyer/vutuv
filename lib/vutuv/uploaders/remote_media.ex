defmodule Vutuv.RemoteMedia do
  @moduledoc """
  Storage for pictures fetched from other networks (issue #1163): the image
  attachments of a cached post and one avatar per cached account.

      <uploads_dir_prefix>/remote_media/posts/<image.id>/img-<hash>.avif
      <uploads_dir_prefix>/remote_media/avatars/<account.id>/avatar-<hash>.avif

  **One tree, two kinds.** They have the same nature — somebody else's picture,
  fetched, derived once and shown small — so they share a storage root, which
  means one `.gitignore` entry and one line in
  `test/vutuv/uploads_gitignore_test.exs` rather than two of each to forget.

  **No private original is kept**, the same deliberate exception
  `Vutuv.ReviewCover` makes and for the same reason: this is not our picture. We
  hold the one derived version we actually display and nothing beyond it, which
  also means there is nothing for `Vutuv.Uploads.Regenerator` to re-derive from
  — after a `Vutuv.Uploads.Spec` change the pictures are simply re-fetched, or
  they age out with their posts.

  The served filename is **content-fingerprinted** (`<hash>` = the first 12 hex
  characters of the SHA-256 of the fetched bytes), so the URL changes whenever
  the bytes do and a stale URL stops resolving. Serving goes through the
  authorizing proxy (`VutuvWeb.RemoteMediaController`), which re-checks both who
  may see the post and the AI gate's verdict per request — so an unreleased
  picture never leaves the proxy and there is no quarantine tree here.
  """

  alias Vutuv.Uploads
  alias Vutuv.Uploads.Spec

  @doc """
  Stores the fetched `bytes` for one remote post image, replacing anything
  stored before. Returns `{:ok, %{file:, width:, height:}}` — `file` being the
  fingerprinted name for the row's `file` column — or `{:error, reason}` when
  the bytes do not decode as an image.
  """
  def store_post_image(bytes, image_id) when is_binary(bytes) and is_binary(image_id) do
    store(bytes, post_dir(image_id), "img", :remote_media)
  end

  @doc """
  Stores the fetched `bytes` as one account's avatar. Same shape as
  `store_post_image/2`; the derived size is the avatar spec, since that is all
  it is ever shown at.
  """
  def store_avatar(bytes, account_id) when is_binary(bytes) and is_binary(account_id) do
    store(bytes, avatar_dir(account_id), "avatar", :remote_avatar)
  end

  defp store(bytes, dir, prefix, spec_name) do
    with {:ok, rotated} <- Spec.open_rotated_binary(bytes) do
      hash = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) |> binary_part(0, 12)

      File.mkdir_p!(Uploads.disk_dir(dir))
      clear(dir, prefix)

      spec = Spec.version(spec_name, :image)
      file = "#{prefix}-#{hash}#{Spec.served_ext()}"

      with :ok <- Spec.write_derived(spec, rotated, Path.join(Uploads.disk_dir(dir), file)) do
        {:ok, %{file: file, width: Image.width(rotated), height: Image.height(rotated)}}
      end
    end
  end

  @doc """
  Absolute on-disk path of a stored picture, or nil. `version` must be exactly
  the fingerprinted name the row carries — anything else never resolves, which
  is what makes the URL unguessable rather than merely private.
  """
  def post_image_path(image_id, version, stored_file) do
    resolve(post_dir(image_id), version, stored_file)
  end

  @doc "The same for an account's avatar."
  def avatar_path(account_id, version, stored_file) do
    resolve(avatar_dir(account_id), version, stored_file)
  end

  defp resolve(dir, version, stored_file) do
    if is_binary(stored_file) and version == Path.rootname(stored_file) do
      path = Path.join(Uploads.disk_dir(dir), stored_file)
      if File.exists?(path), do: path
    end
  end

  @doc "The path nginx would resolve for X-Accel serving of a post image."
  def post_image_accel_path(image_id, version),
    do: "/internal_remote_media/posts/#{image_id}/#{version}#{Spec.served_ext()}"

  @doc "The same for an avatar."
  def avatar_accel_path(account_id, version),
    do: "/internal_remote_media/avatars/#{account_id}/#{version}#{Spec.served_ext()}"

  @doc """
  Root-relative URL of a stored post image, nil when none is stored. Served
  under `/system/` like every other page this project adds, rather than from a
  new root word: profiles own the URL root, and `remote_media` would burn a
  handle nobody could ever claim again.
  """
  def post_image_url(image_id, file) when is_binary(file),
    do: "/system/remote_media/posts/#{image_id}/#{file}"

  def post_image_url(_image_id, _file), do: nil

  @doc "Root-relative URL of a stored avatar, nil when none is stored."
  def avatar_url(account_id, file) when is_binary(file),
    do: "/system/remote_media/avatars/#{account_id}/#{file}"

  def avatar_url(_account_id, _file), do: nil

  @doc """
  Removes every file stored for one post image. Called when the row goes — with
  its post, through expiry, an upstream `Delete`, an unfollow purge or an
  instance block — and when the gate rejects it.
  """
  def delete_post_image(image_id), do: wipe(post_dir(image_id))

  @doc "The same for an account's avatar."
  def delete_avatar(account_id), do: wipe(avatar_dir(account_id))

  defp wipe(dir) do
    File.rm_rf(Uploads.disk_dir(dir))
    :ok
  end

  # The directory a stored picture lives in, relative to the uploads root. The
  # row id, not the source URI: a remote URL is attacker-chosen text and has no
  # business becoming a path.
  defp post_dir(image_id), do: "remote_media/posts/#{image_id}"
  defp avatar_dir(account_id), do: "remote_media/avatars/#{account_id}"

  defp clear(dir, prefix) do
    for file <- Path.wildcard(Path.join(Uploads.disk_dir(dir), "#{prefix}-*")), do: File.rm(file)
    :ok
  end
end
