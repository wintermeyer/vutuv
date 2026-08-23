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

  @doc """
  Every scope this adapter can honour — what `/api/v1/apps` stores and what the
  discovery document advertises. `admin:*` is not among them, see
  `parse_registration/1`.
  """
  def all, do: @scopes

  # Mastodon scope words this adapter recognises but has no API behind: there is
  # no Mastodon admin API here, and `profile`/`crypto` name surfaces vutuv does
  # not serve. Accepted, because a client cannot know which optional halves of
  # the protocol an installation implements — then dropped, because granting a
  # word no route reads would put "administer this site" on the consent screen
  # in exchange for nothing. Refusing them ended a Tokodon login at its first
  # request: it asks for `admin:read admin:write` on every login path, not only
  # a moderator's, so the 422 came before any consent screen (issue #1632). A
  # word in neither list stays a 422 — a misspelt `write:statuse` must not
  # quietly mint a token that cannot post.
  @tolerated ~w(profile crypto)

  def parse_registration(nil), do: {:ok, ["read"]}
  def parse_registration(""), do: {:ok, ["read"]}

  def parse_registration(value) when is_binary(value) do
    {granted, rest} =
      value
      |> String.split(" ", trim: true)
      |> Enum.uniq()
      |> Enum.split_with(&(&1 in @scopes))

    if granted != [] and Enum.all?(rest, &tolerated?/1),
      do: {:ok, granted},
      else: {:error, :invalid_scope}
  end

  def parse_registration(_other), do: {:error, :invalid_scope}

  defp tolerated?("admin:read"), do: true
  defp tolerated?("admin:write"), do: true
  defp tolerated?("admin:read:" <> child), do: child != ""
  defp tolerated?("admin:write:" <> child), do: child != ""
  defp tolerated?(scope), do: scope in @tolerated

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
