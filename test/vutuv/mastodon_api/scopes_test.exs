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

  describe "scopes this adapter has no API for" do
    test "are accepted and dropped rather than refused" do
      # Tokodon's every login path asks for these, moderator or not (#1632).
      assert {:ok, ["read", "write", "follow", "push"]} =
               Scopes.parse_registration("read write follow push admin:read admin:write")

      assert {:ok, ["read"]} = Scopes.parse_registration("read admin:read:accounts")
      assert {:ok, ["read"]} = Scopes.parse_registration("read profile crypto")
    end

    test "still cannot be reached through the authorization step" do
      # Dropping has to happen on both halves or they disagree: the app is
      # registered with the narrowed set, so an authorization asking for the
      # wide one would fail the subset check.
      assert {:ok, ["read", "write"]} =
               Scopes.authorize("read write admin:write", ["read", "write"])
    end

    test "are not in the vocabulary and imply nothing" do
      refute "admin:read" in Scopes.all()
      refute Scopes.granted?(["read", "write", "admin:read"], "admin:read:accounts")
    end

    test "cannot be the only thing a client asks for" do
      assert {:error, :invalid_scope} = Scopes.parse_registration("admin:read admin:write")
    end
  end

  test "a misspelt scope is still refused" do
    assert {:error, :invalid_scope} = Scopes.parse_registration("read write:statuse")
    assert {:error, :invalid_scope} = Scopes.parse_registration("read admin:reed")
  end
end
