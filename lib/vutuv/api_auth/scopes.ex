defmodule Vutuv.ApiAuth.Scopes do
  @moduledoc """
  The one list of API permission scopes.

  Scopes gate what a bearer credential (personal access token or OAuth
  grant) may do, per area and read/write. A `*:write` scope implies its
  `*:read` sibling, so apps that edit don't have to request both.

  `description/1` is the human-readable line the PAT form and the OAuth
  consent screen show; it goes through gettext, so the wording follows the
  viewer's locale.
  """

  use Gettext, backend: VutuvWeb.Gettext

  @scopes ~w(
    profile:read profile:write
    social:read social:write
    posts:read posts:write
    messages:read messages:write
    jobs:read jobs:write
  )

  def all, do: @scopes

  def valid?(scope), do: scope in @scopes

  @doc """
  Does the granted scope list satisfy `required`? Direct membership, or the
  write sibling of a required read scope.
  """
  def granted?(granted, required) when is_list(granted) and is_binary(required) do
    required in granted or write_sibling(required) in granted
  end

  defp write_sibling(scope) do
    case String.split(scope, ":", parts: 2) do
      [area, "read"] -> area <> ":write"
      _other -> nil
    end
  end

  def description("profile:read"),
    do: gettext("Read your profile, including entries only you can see")

  def description("profile:write"),
    do: gettext("Edit your profile and its sections")

  def description("social:read"),
    do: gettext("See your followers, who you follow, and your connections")

  def description("social:write"),
    do: gettext("Follow people, manage connections and endorse tags for you")

  def description("posts:read"),
    do: gettext("Read posts visible to you")

  def description("posts:write"),
    do: gettext("Write, edit and delete your posts")

  def description("messages:read"),
    do: gettext("Read your messages")

  def description("messages:write"),
    do: gettext("Send messages as you")

  def description("jobs:read"),
    do: gettext("Read job postings and organization pages visible to you")

  def description("jobs:write"),
    do: gettext("Post, edit and close job openings as you")
end
