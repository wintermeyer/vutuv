defmodule VutuvWeb.RemoteActorLinkTest do
  @moduledoc """
  The one function that decides where a remote handle leads and what a press on
  it does (`VutuvWeb.FediverseComponents.remote_actor_link/3`), and the boost
  banner as one caller that asks it rather than answering for itself.

  A reader meets somebody from another network in a dozen places here, and every
  one of them is the same question about the same account. This is the answer
  written once: the account card opens over the handle, and the destination
  underneath stays whatever it always was, for the middle click, the copied
  link, the reader who is not signed in and the page whose JavaScript never
  arrived.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse.RemoteAccount
  alias VutuvWeb.FediverseComponents
  alias VutuvWeb.PostComponents

  setup do
    Gettext.put_locale(VutuvWeb.Gettext, "en")
    :ok
  end

  defp account,
    do: %RemoteAccount{
      id: "01a0-account",
      actor_uri: "https://social.example/users/them",
      host: "social.example",
      handle: "them",
      name: "Them Themself"
    }

  describe "remote_actor_link/3" do
    test "an account we hold leads to its page here and opens its card" do
      assert [navigate: path, "data-remote-actor": address] =
               FediverseComponents.remote_actor_link(
                 "01a0-account",
                 "https://social.example/users/them",
                 "@them@social.example"
               )

      assert path == "/system/fediverse/account/01a0-account"
      assert address == "them@social.example"
    end

    test "an account we do not hold leads out to their server and still opens its card" do
      # No page here to show, so the fallback is the only place left — but the
      # card can still answer "who is this", which is what the press is for.
      attrs =
        FediverseComponents.remote_actor_link(
          nil,
          "https://social.example/users/them",
          "@them@social.example"
        )

      assert attrs[:href] == "https://social.example/users/them"
      assert attrs[:target] == "_blank"
      assert attrs[:rel] == "nofollow noopener noreferrer"
      assert attrs[:"data-remote-actor"] == "them@social.example"
    end

    test "a handle that is not an address keeps today's link and no card" do
      # `Handle.display/2` falls back to `@name` and to a bare `@host` when the
      # actor document carried no username. The card is addressed by
      # `user@host` and could only fail on either, so the hook stays off rather
      # than opening a box that says so.
      for handle <- ["@them", "@social.example", nil] do
        attrs = FediverseComponents.remote_actor_link(nil, "https://social.example/x", handle)

        refute Keyword.has_key?(attrs, :"data-remote-actor")
        assert attrs[:href] == "https://social.example/x"
      end
    end
  end

  describe "the boost banner" do
    test "it opens the boosting account's card" do
      # The banner is the only thing on the card explaining why a stranger's
      # post is in the reader's feed, so the account it names is exactly the one
      # they want to know about — and the card is where "and stop showing me
      # their boosts" lives.
      html = render_component(&PostComponents.boosted_banner/1, account: account())

      assert html =~ ~s(data-remote-actor="them@social.example")
      assert html =~ "/system/fediverse/account/01a0-account"
      assert html =~ "Them Themself"
    end
  end
end
