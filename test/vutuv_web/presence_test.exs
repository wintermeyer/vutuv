defmodule VutuvWeb.PresenceTest do
  use ExUnit.Case, async: true

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
