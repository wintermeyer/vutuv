defmodule Vutuv.Uploads do
  @moduledoc """
  Helpers shared by the local-disk uploaders (`Vutuv.Avatar` and
  `Vutuv.Screenshot`).
  """

  @doc """
  The absolute storage root, configured per environment via
  `config :vutuv, :uploads_dir_prefix`. Empty in dev/test and
  `/srv/legacy-vutuv` in production.
  """
  def uploads_dir_prefix, do: Application.get_env(:vutuv, :uploads_dir_prefix, "")

  @doc """
  The absolute on-disk directory for a relative `storage_dir`
  (e.g. `"avatars/7"`), rooted at `uploads_dir_prefix/0`.
  """
  def disk_dir(storage_dir) when is_binary(storage_dir) do
    Path.join(uploads_dir_prefix(), storage_dir)
  end

  @doc """
  Drops a legacy `"?<timestamp>"` cache-busting suffix from a stored filename.
  """
  def strip_query(value) when is_binary(value), do: String.replace(value, ~r/\?\d+$/, "")
end
