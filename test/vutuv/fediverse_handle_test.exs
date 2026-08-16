defmodule Vutuv.FediverseHandleTest do
  @moduledoc """
  How vutuv names an account on another server. One module answers this for
  followers, replies and reactions alike, so the same person cannot read two
  different ways on one page.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Fediverse.Follower
  alias Vutuv.Fediverse.Handle
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemoteAccount

  describe "display_name/1" do
    test "takes out the custom-emoji shortcodes a server's own emoji leave behind" do
      # What arrives from social.cologne: the name carries `:coolified:` and the
      # actor document's `tag` array carries the picture it stands for. We do
      # not host that picture, so the token has nothing to render as.
      assert Handle.display_name("Droid Boy :coolified:") == "Droid Boy"
      assert Handle.display_name(":verified: Alice Anders") == "Alice Anders"
      assert Handle.display_name("Ann :heart: Berg") == "Ann Berg"
      assert Handle.display_name("Cem :blobcat::verified:") == "Cem"
    end

    test "a name that is nothing but shortcodes reads as no name at all" do
      assert Handle.display_name(":verified:") == nil
      assert Handle.display_name("   ") == nil
      assert Handle.display_name(nil) == nil
    end

    test "a colon that is not a shortcode is left alone" do
      # The boundaries must be non-word characters, which is what keeps a time,
      # a URL scheme and a decorated name whole.
      assert Handle.display_name("Alice (Live 10:30:45)") == "Alice (Live 10:30:45)"
      assert Handle.display_name("daniel:// stenberg://") == "daniel:// stenberg://"
      assert Handle.display_name("Spar|fin|dig :: Jan") == "Spar|fin|dig :: Jan"
    end
  end

  describe "the stored rows read through it" do
    test "a followed account, a reply and a follower all drop the shortcode" do
      account = %RemoteAccount{
        name: "Droid Boy :coolified:",
        handle: "droidboy",
        actor_uri: "https://social.cologne/users/droidboy"
      }

      assert RemoteAccount.label(account) == "Droid Boy"
      assert RemoteAccount.display_name(account) == "Droid Boy"

      note = %Note{
        display_name: "Droid Boy :coolified:",
        handle: "droidboy",
        actor_uri: "https://social.cologne/users/droidboy"
      }

      assert Note.label(note) == "Droid Boy"

      follower = %Follower{name: ":verified:", handle: "droidboy"}
      assert Follower.display_name(follower) == nil
    end

    test "an account whose whole name was a shortcode falls back to its handle" do
      account = %RemoteAccount{
        name: ":verified:",
        handle: "droidboy",
        actor_uri: "https://social.cologne/users/droidboy"
      }

      assert RemoteAccount.label(account) == "@droidboy@social.cologne"

      note = %Note{
        display_name: ":verified:",
        handle: "droidboy",
        actor_uri: "https://social.cologne/users/droidboy"
      }

      assert Note.label(note) == "@droidboy@social.cologne"
    end
  end

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
