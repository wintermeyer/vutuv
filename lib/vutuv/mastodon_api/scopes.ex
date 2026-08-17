defmodule Vutuv.MastodonApi.Scopes do
  @moduledoc """
  The Mastodon scope vocabulary accepted by the client adapter. These strings
  are stored on Mastodon grants and tokens as-is, which keeps them isolated
  from the native `/api/2.0` scopes.
  """

  @scopes ~w(
    read
    read:accounts read:blocks read:bookmarks read:favourites read:filters
    read:follows read:lists read:mutes read:notifications read:search read:statuses
    write
    write:accounts write:blocks write:bookmarks write:conversations write:favourites
    write:filters write:follows write:lists write:media write:mutes
    write:notifications write:reports write:statuses
    follow push
  )

  def all, do: @scopes

  def parse_registration(nil), do: {:ok, ["read"]}
  def parse_registration(""), do: {:ok, ["read"]}

  def parse_registration(value) when is_binary(value) do
    scopes = value |> String.split(" ", trim: true) |> Enum.uniq()

    if scopes != [] and Enum.all?(scopes, &(&1 in @scopes)),
      do: {:ok, scopes},
      else: {:error, :invalid_scope}
  end

  def parse_registration(_other), do: {:error, :invalid_scope}

  def authorize(value, registered_scopes) do
    with {:ok, requested} <- parse_registration(value),
         true <- Enum.all?(requested, &granted?(registered_scopes, &1)) do
      {:ok, requested}
    else
      _invalid_or_wider -> {:error, :invalid_scope}
    end
  end

  def granted?(granted, required) when is_list(granted) and is_binary(required) do
    required in granted or parent(required) in granted or legacy_follow?(granted, required)
  end

  defp legacy_follow?(granted, required),
    do: required in ~w(write:blocks write:follows write:mutes) and "follow" in granted

  defp parent("read:" <> _child), do: "read"
  defp parent("write:" <> _child), do: "write"
  defp parent(_scope), do: nil
end
