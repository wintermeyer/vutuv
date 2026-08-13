defmodule Vutuv.FediverseTagAddressFollowTest do
  @moduledoc """
  A member pasting a **tag actor's** address (`@php@tags.<our host>`, issue
  #1330) into a Fediverse follow box is asking to follow that topic. Since the
  address is one of ours, no request can leave: vutuv would be WebFingering
  itself, which is exactly what `own_host?/1` refuses.

  Refusing was the whole answer until now (`{:error, :local_account}`), and that
  is a dead end for the one thing the member wanted. So the tag host joins the
  main host in `follow_remote/2`'s local branch and does the real thing instead
  — a plain `Vutuv.Tags` subscription — the same way an address naming a member
  here has become a plain vutuv follow since #1160.

  DB-only and network-free: every case here is decided before a request would
  be made, so the file stays `async: true` and touches no HTTP stub.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.Fediverse
  alias Vutuv.Tags

  # `tag_host/0` defaults to the `tags.` subdomain of the endpoint host, which
  # is `tags.localhost` in the test env — so nothing has to be put into the
  # application env (which the SQL sandbox would not roll back) and this file
  # can stay async.
  defp tag_address(slug), do: "@#{slug}@#{Fediverse.tag_host()}"

  defp tag_fixture do
    name = Vutuv.Factory.unique_tag_name()
    {:ok, user_tag} = Tags.add_user_tag(insert(:activated_user), name)
    Repo.preload(user_tag, :tag).tag
  end

  describe "follow_remote/2 with a tag actor's address" do
    test "subscribes the member to the tag instead of refusing" do
      user = insert(:activated_user)
      tag = tag_fixture()

      assert {:ok, {:local_tag_follow, followed}} =
               Fediverse.follow_remote(user, tag_address(tag.slug))

      assert followed.id == tag.id
      assert Tags.tag_followed?(user, tag)
    end

    test "accepts the address with a leading @ and in any case" do
      user = insert(:activated_user)
      tag = tag_fixture()

      assert {:ok, {:local_tag_follow, _}} =
               Fediverse.follow_remote(user, String.upcase(tag_address(tag.slug)))

      assert Tags.tag_followed?(user, tag)
    end

    test "does not require the member to federate" do
      # Following a tag is a local subscription: it signs nothing and sends
      # nothing, so the Fediverse participation gate must not stand in front of
      # it — the same reasoning that lets an address naming a member here be
      # followed by somebody who never switched federation on. The factory's
      # member does not federate (`fediverse_followers?` defaults to false), so
      # this is exactly the case `check_can_follow/1` would refuse.
      user = insert(:activated_user)
      refute Fediverse.federated?(user)
      tag = tag_fixture()

      assert {:ok, {:local_tag_follow, _}} = Fediverse.follow_remote(user, tag_address(tag.slug))
    end

    test "following the same tag twice answers :already_following" do
      user = insert(:activated_user)
      tag = tag_fixture()

      assert {:ok, {:local_tag_follow, _}} = Fediverse.follow_remote(user, tag_address(tag.slug))

      assert {:error, :already_following} =
               Fediverse.follow_remote(user, tag_address(tag.slug))
    end

    # An alias has no actor of its own — a topic federates under exactly one
    # address (#1330) — but a member can still have copied the old spelling out
    # of an old post, and landing on the topic beats a dead end.
    test "an alias address subscribes to the canonical tag (issue #1338)" do
      canonical = tag_fixture()
      # The factory's slug sequence already obeys the `^[a-z0-9_]+$` actor
      # grammar the `tags_slug_actor_grammar` CHECK enforces (#1332).
      alias_tag = insert(:tag, merged_into_id: canonical.id)

      assert {:ok, {:local_tag_follow, followed}} =
               Fediverse.follow_remote(insert(:activated_user), tag_address(alias_tag.slug))

      assert followed.id == canonical.id
    end

    test "a tag-host address naming no tag is refused like any unknown handle" do
      assert {:error, :local_account} =
               Fediverse.follow_remote(
                 insert(:activated_user),
                 tag_address("nosuchtag#{System.unique_integer([:positive])}")
               )
    end
  end

  describe "local_tag_for_address/1" do
    test "answers the tag a tag-host address names" do
      tag = tag_fixture()

      assert %{id: id} = Fediverse.local_tag_for_address(tag_address(tag.slug))
      assert id == tag.id
    end

    test "answers nil for a member address, a remote address and junk" do
      member = insert(:activated_user)

      refute Fediverse.local_tag_for_address("@#{member.username}@#{VutuvWeb.Endpoint.host()}")
      refute Fediverse.local_tag_for_address("@someone@geno.social")
      refute Fediverse.local_tag_for_address("not an address")
    end
  end

  # The member half of the same branch needs a dotted endpoint host (the test
  # endpoint answers the dot-less "localhost", which is no Fediverse host at
  # all), so it stays in the `async: false`
  # `Vutuv.FediverseRemoteFollowsTest`, which dresses the endpoint for it.
  test "local_member_for_address/1 answers nil for a tag address" do
    refute Fediverse.local_member_for_address(tag_address(tag_fixture().slug))
  end
end
