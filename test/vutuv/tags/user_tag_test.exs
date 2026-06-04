defmodule Vutuv.Tags.UserTagTest do
  @moduledoc """
  Finding [45]: UserTag.name/1, truncated_name/1 and the Phoenix.Param impl must
  read an already-loaded :tag association and only hit the DB when it is not
  loaded, so the profile page and the user_tag index don't run a query per chip.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Repo
  alias Vutuv.Tags.UserTag

  import Vutuv.Factory

  setup do
    user = insert(:user)
    tag = insert(:tag, name: "Elixir", slug: "elixir")
    user_tag = insert(:user_tag, user: user, tag: tag)
    # Reload bare (tag not loaded) to model the unconverted callers.
    unloaded = Repo.get!(UserTag, user_tag.id)
    {:ok, tag: tag, unloaded: unloaded}
  end

  describe "name/1" do
    test "reads the tag name from an unloaded struct (preloads as a fallback)", %{
      unloaded: unloaded
    } do
      assert match?(%Ecto.Association.NotLoaded{}, unloaded.tag)
      assert UserTag.name(unloaded) == "Elixir"
    end

    test "reads the tag name from a preloaded struct without a query", %{unloaded: unloaded} do
      preloaded = Repo.preload(unloaded, :tag)

      {result, count} = count_queries(fn -> UserTag.name(preloaded) end)
      assert result == "Elixir"
      assert count == 0
    end
  end

  describe "truncated_name/1" do
    test "works on a preloaded struct", %{unloaded: unloaded} do
      preloaded = Repo.preload(unloaded, :tag)
      assert UserTag.truncated_name(preloaded) == "Elixir"
    end

    test "truncates long names", %{tag: tag} do
      user = insert(:user)
      long = String.duplicate("a", 60)
      tag = Repo.update!(Ecto.Changeset.change(tag, name: long))
      user_tag = insert(:user_tag, user: user, tag: tag) |> Repo.preload(:tag)

      truncated = UserTag.truncated_name(user_tag)
      assert String.ends_with?(truncated, " ...")
      assert String.length(truncated) < String.length(long)
    end
  end

  describe "Phoenix.Param.to_param/1" do
    test "returns the tag slug for an unloaded struct", %{unloaded: unloaded} do
      assert Phoenix.Param.to_param(unloaded) == "elixir"
    end

    test "returns the tag slug for a preloaded struct without a query", %{unloaded: unloaded} do
      preloaded = Repo.preload(unloaded, :tag)

      {result, count} = count_queries(fn -> Phoenix.Param.to_param(preloaded) end)
      assert result == "elixir"
      assert count == 0
    end
  end

  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:vutuv, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        # Telemetry is global; under async tests, only count queries emitted
        # from this test process (Ecto runs the handler in the caller).
        if self() == parent, do: send(parent, {ref, :query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_queries(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(ref, acc) do
    receive do
      {^ref, :query} -> drain_queries(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
