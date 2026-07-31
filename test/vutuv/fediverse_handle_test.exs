defmodule Vutuv.FediverseHandleTest do
  @moduledoc """
  How vutuv names an account on another server. One module answers this for
  followers, replies and reactions alike, so the same person cannot read two
  different ways on one page.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Fediverse.Handle

  describe "display/2" do
    test "prefers the handle the remote server told us" do
      assert Handle.display("alice", "https://social.example/users/alice") ==
               "@alice@social.example"

      # The stored handle wins even where the URI would derive something else:
      # `preferredUsername` is what that server calls the account.
      assert Handle.display("alice", "https://social.example/users/12345") ==
               "@alice@social.example"
    end

    test "derives a name from the account URI when none was stored" do
      # The URL shapes these networks actually serve — a row written before the
      # handle column existed still reads properly. This is the case the two
      # reactions already in production fall into.
      for uri <- [
            "https://social.example/users/carol",
            "https://social.example/@carol",
            "https://social.example/u/carol",
            "https://social.example/profile/carol"
          ] do
        assert Handle.display(nil, uri) == "@carol@social.example"
      end
    end

    test "falls back to the bare server when the URI names nothing at all" do
      assert Handle.display(nil, "https://social.example/") == "@social.example"
      assert Handle.display("  ", "https://social.example/") == "@social.example"
      assert Handle.display(nil, "https://social.example/a b c") == "@social.example"
    end

    test "survives a URI that is not one" do
      assert Handle.display("alice", "not a uri") == "@alice"
      assert Handle.display(nil, nil) == nil
    end
  end

  describe "short/1" do
    test "drops the server, which the card's globe chip already names" do
      assert Handle.short("@tagesschau@ard.social") == "@tagesschau"
      assert Handle.short("@alice@social.example") == "@alice"
    end

    test "leaves a handle that is only a server alone" do
      # `display/2`'s last fallback: no username anywhere, so the host IS the
      # name and there is nothing to cut.
      assert Handle.short("@social.example") == "@social.example"
      assert Handle.short("@alice") == "@alice"
      assert Handle.short(nil) == nil
    end
  end

  describe "host/1" do
    test "is the URI's host, or nil" do
      assert Handle.host("https://social.example/users/alice") == "social.example"
      assert Handle.host("gibberish") == nil
      assert Handle.host(nil) == nil
    end
  end
end
