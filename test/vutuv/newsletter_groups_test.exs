defmodule Vutuv.NewsletterGroupsTest do
  @moduledoc """
  Newsletter audiences ("groups"): the live filter count (`audience_count/1`),
  the fixed-snapshot materialization (`create_group/1` / `update_group/2`), the
  group subtraction that makes "test run of 100, then the rest" partition
  cleanly, and the group-targeted broadcast (members ∩ still-eligible).
  """
  use Vutuv.DataCase

  alias Vutuv.BerlinTime
  alias Vutuv.Newsletters
  alias Vutuv.Newsletters.NewsletterGroupMember

  defp member(value, attrs \\ []) do
    user = insert(:activated_user, attrs)
    insert(:email, user: user, value: value)
    user
  end

  defp born(age), do: Date.new!(BerlinTime.today().year - age, 1, 1)

  defp member_ids(group) do
    Repo.all(from(m in NewsletterGroupMember, where: m.group_id == ^group.id, select: m.user_id))
  end

  describe "audience_count/1" do
    test "filters by language (locale)" do
      member("en@x.com", locale: "en")
      member("de@x.com", locale: "de")

      assert Newsletters.audience_count(%{}) == 2
      assert Newsletters.audience_count(%{locales: ["de"]}) == 1
      assert Newsletters.audience_count(%{locales: ["en", "de"]}) == 2
    end

    test "filters by country" do
      with_address = member("a@x.com")
      insert(:address, user: with_address, country: "Germany")
      member("b@x.com")

      assert Newsletters.audience_count(%{country: "Germany"}) == 1
      assert Newsletters.audience_count(%{country: "France"}) == 0
    end

    test "filters by age range" do
      member("young@x.com", birthdate: born(20))
      member("old@x.com", birthdate: born(50))
      member("unknown@x.com", birthdate: nil)

      assert Newsletters.audience_count(%{}) == 3
      assert Newsletters.audience_count(%{min_age: 30}) == 1
      assert Newsletters.audience_count(%{max_age: 30}) == 1
      assert Newsletters.audience_count(%{min_age: 18, max_age: 40}) == 1
    end

    test "filters by username with wildcards and contains-match" do
      member("a@x.com", username: "stefan.wintermeyer")
      member("b@x.com", username: "erika.musterfrau")

      assert Newsletters.audience_count(%{username: "stefan*"}) == 1
      assert Newsletters.audience_count(%{username: "*meyer"}) == 1
      assert Newsletters.audience_count(%{username: "wintermeyer"}) == 1
      assert Newsletters.audience_count(%{username: "*.muster*"}) == 1
      assert Newsletters.audience_count(%{username: "nobody"}) == 0
    end

    test "username matching escapes literal underscores" do
      member("a@x.com", username: "a_b")
      member("b@x.com", username: "axb")

      # "a_b" has no wildcard, so the "_" is literal: it matches a_b, not axb.
      assert Newsletters.audience_count(%{username: "a_b"}) == 1
    end

    test "adds (unions) the members of included groups, bypassing the filters" do
      de = member("de@x.com", locale: "de")
      en = member("en@x.com", locale: "en")
      {:ok, en_group} = Newsletters.create_group(%{"name" => "EN", "locales" => ["en"]})

      ids = Newsletters.audience_user_ids(%{locales: ["de"], included_group_ids: [en_group.id]})
      assert MapSet.new(ids) == MapSet.new([de.id, en.id])
    end

    test "include then exclude: subtraction wins over addition" do
      _de = member("de@x.com", locale: "de")
      en = member("en@x.com", locale: "en")
      {:ok, en_group} = Newsletters.create_group(%{"name" => "EN", "locales" => ["en"]})

      ids =
        Newsletters.audience_user_ids(%{
          locales: ["de"],
          included_group_ids: [en_group.id],
          excluded_group_ids: [en_group.id]
        })

      refute en.id in ids
    end

    test "filters by tag" do
      tag = insert(:tag, name: "Elixir")
      tagged = member("a@x.com")
      insert(:user_tag, user: tagged, tag: tag)
      member("b@x.com")

      assert Newsletters.audience_count(%{tag_id: tag.id}) == 1
      assert Newsletters.find_tag("elixir").id == tag.id
    end

    test "only counts emailable, subscribed members" do
      member("ok@x.com")
      member("opted-out@x.com", newsletter_emails?: false)
      insert(:activated_user)

      assert Newsletters.audience_count(%{}) == 1
    end
  end

  describe "create_group/1" do
    test "snapshots the matching members and caches the count" do
      for i <- 1..3, do: member("u#{i}@x.com")

      assert {:ok, group} = Newsletters.create_group(%{"name" => "Everyone"})
      assert group.member_count == 3
      assert length(member_ids(group)) == 3
    end

    test "caps the snapshot at max_size, oldest first by default" do
      m1 = member("u1@x.com")
      m2 = member("u2@x.com")
      _m3 = member("u3@x.com")

      assert {:ok, group} = Newsletters.create_group(%{"name" => "Test 2", "max_size" => "2"})
      assert group.member_count == 2
      assert MapSet.new(member_ids(group)) == MapSet.new([m1.id, m2.id])
    end

    test "a random sample caps to max_size from the whole pool" do
      pool = for i <- 1..5, do: member("u#{i}@x.com").id

      assert {:ok, group} =
               Newsletters.create_group(%{
                 "name" => "Random 2",
                 "max_size" => "2",
                 "random_sample" => "true"
               })

      assert group.member_count == 2
      assert MapSet.subset?(MapSet.new(member_ids(group)), MapSet.new(pool))
    end

    test "requires a name" do
      assert {:error, changeset} = Newsletters.create_group(%{"name" => ""})
      assert %{name: _} = errors_on(changeset)
    end

    test "errors when the tag name does not resolve" do
      assert {:error, changeset} =
               Newsletters.create_group(%{"name" => "X", "tag_name" => "no-such-tag"})

      assert %{tag_name: _} = errors_on(changeset)
    end

    test "resolves a tag name to a tag filter" do
      tag = insert(:tag, name: "Elixir")
      tagged = member("a@x.com")
      insert(:user_tag, user: tagged, tag: tag)
      member("b@x.com")

      assert {:ok, group} =
               Newsletters.create_group(%{"name" => "Elixir people", "tag_name" => "elixir"})

      assert group.tag_id == tag.id
      assert group.member_count == 1
    end
  end

  describe "per-account include / exclude" do
    test "included_user_ids adds specific accounts (union), bypassing the filters" do
      de = member("de@x.com", locale: "de")
      en = member("en@x.com", locale: "en")

      ids = Newsletters.audience_user_ids(%{locales: ["de"], included_user_ids: [en.id]})
      assert MapSet.new(ids) == MapSet.new([de.id, en.id])
    end

    test "excluded_user_ids removes specific accounts" do
      keep = member("keep@x.com", locale: "de")
      drop = member("drop@x.com", locale: "de")

      ids = Newsletters.audience_user_ids(%{locales: ["de"], excluded_user_ids: [drop.id]})
      assert ids == [keep.id]
    end

    test "exclusion wins over inclusion for the same account" do
      u = member("u@x.com")
      ids = Newsletters.audience_user_ids(%{included_user_ids: [u.id], excluded_user_ids: [u.id]})
      refute u.id in ids
    end

    test "search_members/1 finds eligible members by handle; audience_member_ids/2 flags the in-group ones" do
      grace = member("g@x.com", username: "grace-hopper")
      ada = member("a@x.com", username: "ada-lovelace")

      assert Enum.map(Newsletters.search_members("grace*"), & &1.id) == [grace.id]

      # No filter matches (both en), so only the included account is in-group.
      checked =
        Newsletters.audience_member_ids(
          %{locales: ["de"], included_user_ids: [grace.id]},
          [grace.id, ada.id]
        )

      assert checked == [grace.id]
    end
  end

  describe "preview & member listing" do
    test "audience_preview/2 returns a profile-linkable sample of matches" do
      ann = member("a@x.com", first_name: "Ann")
      member("b@x.com", first_name: "Bob")

      preview = Newsletters.audience_preview(%{}, per_page: 10)
      assert length(preview) == 2
      assert ann.id in Enum.map(preview, & &1.id)
      # listing_fields carry what a profile link/avatar needs.
      assert Enum.all?(preview, &(&1.username != nil and &1.first_name != nil))
    end

    test "audience_preview/2 paginates with page + per_page" do
      for i <- 1..5, do: member("u#{i}@x.com")

      p1 = Newsletters.audience_preview(%{}, page: 1, per_page: 2)
      p2 = Newsletters.audience_preview(%{}, page: 2, per_page: 2)
      p3 = Newsletters.audience_preview(%{}, page: 3, per_page: 2)

      assert {length(p1), length(p2), length(p3)} == {2, 2, 1}
      assert MapSet.disjoint?(MapSet.new(p1, & &1.id), MapSet.new(p2, & &1.id))
    end

    test "list_group_members/1 returns the frozen members, group_member_count/1 counts them" do
      m1 = member("a@x.com")
      m2 = member("b@x.com")
      {:ok, group} = Newsletters.create_group(%{"name" => "All"})

      members = Newsletters.list_group_members(group)
      assert MapSet.new(members, & &1.id) == MapSet.new([m1.id, m2.id])
      assert Newsletters.group_member_count(group) == 2
    end
  end

  describe "update_group/2" do
    test "re-snapshots when the filters change" do
      member("a@x.com")
      member("b@x.com")
      {:ok, group} = Newsletters.create_group(%{"name" => "G", "max_size" => "1"})
      assert group.member_count == 1

      {:ok, group} = Newsletters.update_group(group, %{"name" => "G", "max_size" => "5"})
      assert group.member_count == 2
    end
  end

  describe "subtraction (test run, then the rest)" do
    test "the rest group excludes the test group, and they partition the audience" do
      m1 = member("a@x.com")
      m2 = member("b@x.com")
      m3 = member("c@x.com")

      {:ok, test_group} = Newsletters.create_group(%{"name" => "Test", "max_size" => "1"})
      assert test_group.member_count == 1

      {:ok, rest} =
        Newsletters.create_group(%{"name" => "Rest", "excluded_group_ids" => [test_group.id]})

      assert rest.member_count == 2

      test_ids = MapSet.new(member_ids(test_group))
      rest_ids = MapSet.new(member_ids(rest))

      assert MapSet.disjoint?(test_ids, rest_ids)
      assert MapSet.union(test_ids, rest_ids) == MapSet.new([m1.id, m2.id, m3.id])
    end
  end

  describe "group-targeted broadcast" do
    setup do
      {:ok, admin: insert(:activated_user, admin?: true)}
    end

    test "sends only to the group's members", %{admin: admin} do
      member("in@x.com", locale: "de")
      member("out@x.com", locale: "en")
      {:ok, group} = Newsletters.create_group(%{"name" => "DE", "locales" => ["de"]})

      {:ok, newsletter} =
        Newsletters.create_newsletter(%{"subject" => "Hi", "body" => "Hello"}, admin)

      assert {:ok, :started} = Newsletters.start_broadcast(newsletter, group.id)
      flush_emails()

      newsletter = Newsletters.get_newsletter!(newsletter.id)
      assert newsletter.status == "sent"
      assert newsletter.group_id == group.id
      assert Enum.map(Newsletters.list_deliveries(newsletter), & &1.email) == ["in@x.com"]
    end

    test "re-checks eligibility, skipping snapshot members who since unsubscribed", %{
      admin: admin
    } do
      member = member("u@x.com", locale: "de")
      {:ok, group} = Newsletters.create_group(%{"name" => "DE", "locales" => ["de"]})
      assert group.member_count == 1

      # Member opts out after the snapshot was frozen.
      Repo.update_all(from(u in Vutuv.Accounts.User, where: u.id == ^member.id),
        set: [newsletter_emails?: false]
      )

      {:ok, newsletter} =
        Newsletters.create_newsletter(%{"subject" => "Hi", "body" => "Hi"}, admin)

      assert {:ok, :started} = Newsletters.start_broadcast(newsletter, group.id)
      flush_emails()

      assert Newsletters.get_newsletter!(newsletter.id).recipient_count == 0
    end
  end
end
