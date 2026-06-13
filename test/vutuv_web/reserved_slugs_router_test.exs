defmodule VutuvWeb.ReservedSlugsRouterTest do
  @moduledoc """
  Profiles live at the URL root (`/:slug`), so any router path whose first
  segment is a *valid handle shape* must be in `ReservedSlugs` — otherwise a
  member could register that handle and either shadow the route or be shadowed
  by it (issue: `health` and `sitemaps` slipped through). This test enumerates
  the router and fails the build on the next such drift.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.ReservedSlugs

  # The handle grammar: ^[a-z0-9_]+$, 3-15 chars (Vutuv.Accounts.User.slug_changeset).
  @handle_shape ~r/^[a-z0-9_]{3,15}$/

  test "every router prefix that is a valid handle shape is reserved" do
    reserved = MapSet.new(ReservedSlugs.list())

    offenders =
      VutuvWeb.Router.__routes__()
      |> Enum.map(& &1.path)
      |> Enum.map(&first_segment/1)
      |> Enum.filter(&(&1 && Regex.match?(@handle_shape, &1)))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(reserved, &1))
      |> Enum.sort()

    assert offenders == [],
           "router prefixes missing from ReservedSlugs (a handle could shadow them): " <>
             Enum.join(offenders, ", ")
  end

  defp first_segment("/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [seg | _] -> seg
      _ -> nil
    end
  end

  defp first_segment(_), do: nil
end
