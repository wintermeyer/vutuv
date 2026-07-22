defmodule VutuvWeb.PresenceTest do
  @moduledoc """
  async: false - these tests put members on the shared, global presence topic,
  which no sandbox rolls back. Running them concurrently made the two modules
  that assert on that same set (`VutuvWeb.Admin.DashboardLiveTest`,
  `VutuvWeb.ShellLivePresenceTest`) fail intermittently: a member tracked here
  raised their "online now" count and their `presence_diff` satisfied a
  `assert_receive` meant for the diff those tests had just triggered, so they
  flushed the LiveView before its own join arrived. Those two are `async: false`
  for that reason; this module has to be too, or they only avoid each other.
  """
  use ExUnit.Case, async: false

  alias VutuvWeb.Presence

  test "presence server is running and a fresh topic is empty" do
    assert Presence.list("messages:none") == %{}
  end

  test "track_user puts a member on the site-wide online set; online?/2 reads it" do
    id = Vutuv.UUIDv7.generate()
    refute Presence.online?(Presence.online_ids(), id)

    {:ok, _ref} = Presence.track_user(self(), id)

    assert Presence.online?(Presence.online_ids(), id)
  end

  test "online?/2 stringifies the id so a binary id and its string agree" do
    id = Vutuv.UUIDv7.generate()
    {:ok, _ref} = Presence.track_user(self(), id)

    assert Presence.online?(Presence.online_ids(), to_string(id))
  end

  test "track_user is a no-op for a nil id" do
    assert Presence.track_user(self(), nil) == :ok
  end
end
