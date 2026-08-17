defmodule Vutuv.MastodonApi.ScopesTest do
  use ExUnit.Case, async: true

  alias Vutuv.MastodonApi.Scopes

  test "a parent read scope grants only its read children" do
    assert Scopes.granted?(["read"], "read:accounts")
    assert Scopes.granted?(["read"], "read:statuses")
    refute Scopes.granted?(["read"], "write:statuses")
  end

  test "write never implies read" do
    assert Scopes.granted?(["write"], "write:statuses")
    refute Scopes.granted?(["write"], "read:statuses")
  end

  test "legacy follow grants the granular relationship write scopes" do
    assert Scopes.granted?(["follow"], "write:follows")
    assert Scopes.granted?(["follow"], "write:mutes")
    assert Scopes.granted?(["follow"], "write:blocks")
    refute Scopes.granted?(["follow"], "write:statuses")
  end

  test "authorization cannot exceed the scopes registered by the client" do
    assert {:ok, ["read:accounts"]} = Scopes.authorize("read:accounts", ["read"])
    assert {:error, :invalid_scope} = Scopes.authorize("write:statuses", ["read"])
  end
end
