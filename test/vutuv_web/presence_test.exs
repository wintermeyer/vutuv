defmodule VutuvWeb.PresenceTest do
  use ExUnit.Case, async: true

  test "presence server is running and a fresh topic is empty" do
    assert VutuvWeb.Presence.list("messages:none") == %{}
  end
end
