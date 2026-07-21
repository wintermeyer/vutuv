defmodule Vutuv.TagsTest do
  use Vutuv.DataCase, async: true
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.TagFollow
  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement

  describe "create_or_link_tag/2" do
    import Ecto.Changeset

    defp link(value) do
      %UserTag{}
      |> change(%{})
      |> Tag.create_or_link_tag(%{"value" => value})
    end

    test "links to an existing tag whose name matches case-insensitively" do
      name = unique_tag_name("Elixir")
      tag = insert(:tag, name: name, slug: String.downcase(name))
      changeset = link(String.downcase(name))
      assert get_change(changeset, :tag_id) == tag.id
    end

    test "creates the tag up front and links its committed id (deadlock-safe get-or-create)" do
      # No committed row matches, so create_or_link_tag/2 resolves the value to a
      # brand-new tag. It must INSERT that tag in its own ON CONFLICT statement and
      # link the committed id, NOT defer the insert as a nested put_assoc: two
      # concurrent sign-ups sharing a tag both see find_by_value/1 == nil, and the
      # old put_assoc path had each INSERT the same tags.slug inside its own
      # user_tag insert, forming the register_user lock cycle (Postgres 40P01
      # deadlock — the intermittent async-suite flake).
      changeset = link("Rust")

      tag_id = get_change(changeset, :tag_id)
      assert tag_id
      refute get_change(changeset, :tag)

      tag = Repo.get!(Tag, tag_id)
      assert tag.name == "Rust"
      assert tag.slug =~ "rust"
    end

    test "resolving the same new value twice is idempotent (one row, no unique-violation race)" do
      name = unique_tag_name("Elixir")
      first = get_change(link(name), :tag_id)
      second = get_change(link(String.downcase(name)), :tag_id)

      assert first == second
      assert Repo.aggregate(Tag, :count) == 1
    end

    test "a new tag keeps the entered casing as its display name" do
      # "UX" must not become the chip "ux" - only the slug is lowercased.
      # (Lowercase chips on old profiles come from 2017 legacy tag names,
      # not from this path.)
      user = insert(:user)
      {:ok, user_tag} = Tags.add_user_tag(user, "WebAssembly")

      tag = Repo.preload(user_tag, :tag).tag
      assert tag.name == "WebAssembly"
      assert tag.slug == "webassembly"
    end

    test "a multi-word value links to an existing spaced tag case-insensitively" do
      # Multi-word tags are first-class again: a spaced value attaches the
      # existing spaced tag (matched case-insensitively by name), it does not
      # mint a duplicate.
      name = unique_tag_name("Ruby on Rails")
      slug = name |> String.downcase() |> String.replace(" ", "-")
      tag = insert(:tag, name: name, slug: slug)

      changeset = link(String.downcase(name))
      assert get_change(changeset, :tag_id) == tag.id
    end

    test "a multi-word value with no match creates one spaced tag and links it" do
      name = unique_tag_name("Ruby on Rails")
      changeset = link(name)

      tag_id = get_change(changeset, :tag_id)
      assert tag_id

      tag = Repo.get!(Tag, tag_id)
      assert tag.name == name
      assert tag.slug =~ "ruby"
    end
  end

  describe "tag names are stored first-writer-wins, matched case-insensitively" do
    # The contract: a tag keeps the casing whoever created it first typed
    # (capitals and all) and is never auto-downcased; every lookup ignores case.
    # This guards against re-introducing the old "downcase every tag" behavior at
    # any entry point.
    import Ecto.Changeset

    test "the first writer's spelling is what every later member links to" do
      first = insert(:user)
      later = insert(:user)

      assert {:ok, ut1} = Tags.add_user_tag(first, "PostgreSQL")
      tag = Repo.preload(ut1, :tag).tag
      assert tag.name == "PostgreSQL"
      assert tag.slug == "postgresql"

      # A later member typing a different casing attaches the SAME tag: the
      # stored name stays "PostgreSQL" and no case-variant duplicate is minted.
      assert {:ok, ut2} = Tags.add_user_tag(later, "postgresql")
      assert Repo.preload(ut2, :tag).tag.id == tag.id
      assert Repo.get!(Tag, tag.id).name == "PostgreSQL"
      assert Repo.aggregate(Tag, :count) == 1
    end

    test "find_by_value/1 matches by name and by slug, case-insensitively" do
      tag = insert(:tag, name: "GraphQL", slug: "graphql")

      assert Tag.find_by_value("graphql").id == tag.id
      assert Tag.find_by_value("GRAPHQL").id == tag.id
      assert Tag.find_by_value("GraphQL").id == tag.id
      assert is_nil(Tag.find_by_value("Rust"))
    end

    test "the admin create form stores the typed name verbatim" do
      changeset = Tag.changeset(%Tag{}, %{"name" => "TypeScript", "slug" => "typescript"})
      assert get_change(changeset, :name) == "TypeScript"
      assert {:ok, tag} = Repo.insert(changeset)
      assert tag.name == "TypeScript"
    end

    test "the admin edit form can recapitalize a legacy lowercase name" do
      name = unique_tag_name("Elixir")
      legacy = String.downcase(name)
      tag = insert(:tag, name: legacy, slug: legacy)

      assert {:ok, updated} = tag |> Tag.edit_changeset(%{"name" => name}) |> Repo.update()
      assert updated.name == name
    end
  end

  describe "a profile is capped at max_user_tags/0 tags" do
    # A few members overdid the tag count, so a profile may hold at most
    # `max_user_tags/0` tags. The cap bites only when tags *change*: an existing
    # profile that already exceeds it (from before the cap) keeps every tag, but
    # can add none until it drops back under the ceiling.
    defp count_tags(user),
      do: Repo.aggregate(from(ut in UserTag, where: ut.user_id == ^user.id), :count)

    # Fill a user right up to the cap through the real chokepoint.
    defp fill_to_limit(user) do
      for n <- 1..Tags.max_user_tags() do
        assert {:ok, _} = Tags.add_user_tag(user, "Skill#{n}")
      end

      user
    end

    test "adding tags up to the limit is allowed" do
      user = fill_to_limit(insert(:user))
      assert count_tags(user) == Tags.max_user_tags()
    end

    test "the tag one over the limit is refused and not stored" do
      user = fill_to_limit(insert(:user))

      assert {:error, %Ecto.Changeset{} = changeset} = Tags.add_user_tag(user, "OneTooMany")
      refute changeset.valid?
      assert count_tags(user) == Tags.max_user_tags()
      refute Repo.exists?(from(t in Tag, where: t.name == "OneTooMany"))
    end

    test "at_user_tag_limit?/1 flips once the profile is full" do
      user = insert(:user)
      refute Tags.at_user_tag_limit?(user)

      fill_to_limit(user)
      assert Tags.at_user_tag_limit?(user)
    end

    test "a profile already over the limit keeps its tags but can add none (grandfathered)" do
      # Legacy profiles from before the cap are inserted straight, bypassing the
      # chokepoint, to reproduce the over-limit state.
      user = insert(:user)
      for _ <- 1..(Tags.max_user_tags() + 5), do: insert(:user_tag, user: user, tag: build(:tag))

      assert count_tags(user) == Tags.max_user_tags() + 5
      assert {:error, _} = Tags.add_user_tag(user, "Nope")
      assert count_tags(user) == Tags.max_user_tags() + 5
    end

    test "removing a tag frees a slot again" do
      user = insert(:user)
      {:ok, first} = Tags.add_user_tag(user, "First")

      for n <- 2..Tags.max_user_tags(), do: {:ok, _} = Tags.add_user_tag(user, "Skill#{n}")
      assert {:error, _} = Tags.add_user_tag(user, "Blocked")

      {:ok, _} = Tags.delete_user_tag(first)
      assert {:ok, _} = Tags.add_user_tag(user, "NowFits")
      assert count_tags(user) == Tags.max_user_tags()
    end
  end

  describe "parse_tag_names/1" do
    test "an unquoted comma or space still separates tags" do
      assert Tags.parse_tag_names("Elixir, Phoenix Go") == ["Elixir", "Phoenix", "Go"]
    end

    test "an unquoted run of words is one tag per word" do
      assert Tags.parse_tag_names("Ruby on Rails") == ["Ruby", "on", "Rails"]
    end

    test "a quoted phrase is kept as one multi-word tag" do
      assert Tags.parse_tag_names(~s("Ruby on Rails")) == ["Ruby on Rails"]
    end

    test "quoted phrases mix with bare tags in typed order" do
      assert Tags.parse_tag_names(~s(Elixir, "Ruby on Rails", "Node JS" Go)) ==
               ["Elixir", "Ruby on Rails", "Node JS", "Go"]
    end

    test "typographic quotes from mobile keyboards group too" do
      assert Tags.parse_tag_names("“Ruby on Rails”, „Node JS“") ==
               ["Ruby on Rails", "Node JS"]
    end

    test "an unbalanced quote degrades to word splitting" do
      assert Tags.parse_tag_names(~s("Ruby on Rails)) == ["Ruby", "on", "Rails"]
    end

    test "collapses runs of whitespace inside a quoted tag" do
      assert Tags.parse_tag_names(~s("Ruby   on  Rails")) == ["Ruby on Rails"]
    end

    test "trims padding and drops empty segments" do
      assert Tags.parse_tag_names(" PHP , , Go ") == ["PHP", "Go"]
    end

    test "returns [] for blank and nil input" do
      assert Tags.parse_tag_names("   ") == []
      assert Tags.parse_tag_names(nil) == []
    end
  end

  describe "a leading # (the hashtag form) is stripped" do
    # Members naturally type tags with a leading `#` (posts render `#hashtag`
    # links), so `#elixir` is stored as the tag `elixir` — and links to the same
    # global tag as `elixir`, never a `#`-prefixed duplicate. Only a *leading*
    # run of `#` is removed, so `C#` keeps its trailing `#`.
    import Ecto.Changeset

    test "parse_tag_names strips a leading # and splits the hashtag forms" do
      assert Tags.parse_tag_names("#Elixir, #Phoenix #Go") == ["Elixir", "Phoenix", "Go"]
    end

    test "parse_tag_names drops a bare # that normalizes to nothing" do
      assert Tags.parse_tag_names("#elixir # #") == ["elixir"]
    end

    test "create_or_link_tag links #Elixir to the existing Elixir tag" do
      name = unique_tag_name("Elixir")
      tag = insert(:tag, name: name, slug: String.downcase(name))

      changeset =
        %UserTag{} |> change(%{}) |> Tag.create_or_link_tag(%{"value" => "#" <> name})

      assert get_change(changeset, :tag_id) == tag.id
    end

    test "add_user_tag stores #elixir as the tag elixir" do
      user = insert(:user)
      name = unique_tag_name("elixir")

      assert {:ok, user_tag} = Tags.add_user_tag(user, "#" <> name)
      tag = Repo.preload(user_tag, :tag).tag
      assert tag.name == name
      assert tag.slug == name
    end

    test "add_user_tag keeps a trailing # (C# stays C#)" do
      user = insert(:user)

      assert {:ok, user_tag} = Tags.add_user_tag(user, "C#")
      assert Repo.preload(user_tag, :tag).tag.name == "C#"
    end
  end

  describe "preview_tag_names/1" do
    # Backs the live preview on the add-tag form (issue #848): the names a
    # submit of the given input will actually attach, resolved the same way
    # `create_or_link_tag/2` links.

    test "keeps a fresh name exactly as typed" do
      assert Tags.preview_tag_names("WebAssembly Rust") == ["WebAssembly", "Rust"]
    end

    test "an existing tag wins with its stored display name" do
      insert(:tag, name: "ahmetsun", slug: "ahmetsun")
      insert(:tag, name: "CLAUDE", slug: "claude")

      # Matched case-insensitively by name ("AhmetSun" → "ahmetsun") and by
      # slug ("claude" → the tag displaying "CLAUDE").
      assert Tags.preview_tag_names("AhmetSun, claude, Fresh") ==
               ["ahmetsun", "CLAUDE", "Fresh"]
    end

    test "collapses case-insensitive duplicates, keeping the first spelling" do
      assert Tags.preview_tag_names("php PHP php Go") == ["php", "Go"]
    end

    test "strips the hashtag form and blank segments" do
      assert Tags.preview_tag_names("#Elixir, , #") == ["Elixir"]
    end

    test "returns [] for blank and nil input" do
      assert Tags.preview_tag_names("  ,  ") == []
      assert Tags.preview_tag_names(nil) == []
    end
  end

  describe "add_user_tag/2 stores multi-word tags" do
    test "a multi-word name is stored as one spaced tag" do
      user = insert(:user)
      name = unique_tag_name("Ruby on Rails")

      assert {:ok, user_tag} = Tags.add_user_tag(user, name)
      tag = Repo.preload(user_tag, :tag).tag
      assert tag.name == name
      assert tag.slug =~ "ruby"
    end

    test "a later member linking a spaced tag keeps the first spelling" do
      first = insert(:user)
      later = insert(:user)
      name = unique_tag_name("Ruby on Rails")

      assert {:ok, ut1} = Tags.add_user_tag(first, name)
      tag = Repo.preload(ut1, :tag).tag

      assert {:ok, ut2} = Tags.add_user_tag(later, String.downcase(name))
      assert Repo.preload(ut2, :tag).tag.id == tag.id
      assert Repo.aggregate(Tag, :count) == 1
    end

    test "a single-word name is stored" do
      user = insert(:user)
      name = unique_tag_name("Elixir")

      assert {:ok, user_tag} = Tags.add_user_tag(user, name)
      assert Repo.preload(user_tag, :tag).tag.name == name
    end

    test "collapses stray whitespace runs into single spaces" do
      user = insert(:user)
      suffix = System.unique_integer([:positive])

      assert {:ok, user_tag} = Tags.add_user_tag(user, "Ruby\non   Rails-#{suffix}")
      assert Repo.preload(user_tag, :tag).tag.name == "Ruby on Rails-#{suffix}"
    end
  end

  describe "user_tags" do
    test "UserTag.name/1 returns the tag's name" do
      user = insert(:user)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: user, tag: tag)
      assert UserTag.name(user_tag) == tag.name
    end
  end

  describe "recommended_users/1" do
    test "hides unactivated and moderation-hidden accounts" do
      # Same visibility gate as search and the most-followed listing: a frozen
      # or never-activated account must not surface on the public tag page.
      tag = insert(:tag)
      visible = insert(:user, email_confirmed?: true)
      unactivated = insert(:user)
      frozen = insert(:user, email_confirmed?: true, frozen_at: ~N[2026-01-01 00:00:00])

      for owner <- [visible, unactivated, frozen] do
        insert(:user_tag, user: owner, tag: tag)
      end

      ids = Tag.recommended_users(tag) |> Enum.map(& &1.id)

      assert visible.id in ids
      refute unactivated.id in ids
      refute frozen.id in ids
    end

    test "ranks by VISIBLE endorsers only, so a hidden endorser can't inflate the ranking" do
      # The ranking must agree with the endorsement counts shown elsewhere
      # (which already exclude hidden/unconfirmed endorsers). Otherwise a member
      # endorsed only by moderation-hidden accounts would outrank a member with a
      # single genuine, visible endorsement.
      tag = insert(:tag)

      # A: one visible endorsement.
      a = insert(:user, email_confirmed?: true)
      a_tag = insert(:user_tag, user: a, tag: tag)
      insert(:user_tag_endorsement, user_tag: a_tag, user: insert(:user, email_confirmed?: true))

      # B: three endorsements, every endorser hidden or unconfirmed (count 0).
      b = insert(:user, email_confirmed?: true)
      b_tag = insert(:user_tag, user: b, tag: tag)

      for endorser <- [
            insert(:user),
            insert(:user, email_confirmed?: true, frozen_at: ~N[2026-01-01 00:00:00]),
            insert(:user, email_confirmed?: true, deactivated_at: ~N[2026-01-01 00:00:00])
          ] do
        insert(:user_tag_endorsement, user_tag: b_tag, user: endorser)
      end

      ids = Tag.recommended_users(tag) |> Enum.map(& &1.id)

      assert a.id in ids and b.id in ids
      assert Enum.find_index(ids, &(&1 == a.id)) < Enum.find_index(ids, &(&1 == b.id))
    end
  end

  describe "endorsement count visibility" do
    # The endorsement count must obey the project-wide rule that hidden
    # accounts never count toward a public tally (issue #783), the same gate
    # already applied to the follower / connection / tag-member / most-followed
    # counts. A tag endorsed by one visible and four hidden members reads "1".
    defp tag_with_mixed_endorsers do
      tag_owner = insert(:user, email_confirmed?: true)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: tag_owner, tag: tag)

      visible = insert(:user, email_confirmed?: true)
      unactivated = insert(:user)
      frozen = insert(:user, email_confirmed?: true, frozen_at: ~N[2026-01-01 00:00:00])
      suspended = insert(:user, email_confirmed?: true, suspended_until: ~N[2099-12-31 23:59:59])
      deactivated = insert(:user, email_confirmed?: true, deactivated_at: ~N[2026-01-01 00:00:00])

      for endorser <- [visible, unactivated, frozen, suspended, deactivated] do
        insert(:user_tag_endorsement, user_tag: user_tag, user: endorser)
      end

      {tag_owner, user_tag}
    end

    test "ordered_by_endorsements/0 counts only currently-visible endorsers" do
      {tag_owner, _user_tag} = tag_with_mixed_endorsers()

      [counted] =
        UserTag.ordered_by_endorsements()
        |> where(user_id: ^tag_owner.id)
        |> Repo.all()

      assert counted.endorsement_count == 1
    end

    test "UserTagEndorsement.visible/1 preloads only currently-visible endorsers" do
      {_tag_owner, user_tag} = tag_with_mixed_endorsers()

      user_tag = Repo.preload(user_tag, endorsements: UserTagEndorsement.visible())

      assert length(user_tag.endorsements) == 1
    end

    test "count_visible_endorsements/1 counts only currently-visible endorsers" do
      {_tag_owner, user_tag} = tag_with_mixed_endorsers()

      assert Tags.count_visible_endorsements(user_tag.id) == 1
    end
  end

  describe "endorsed?/2 and delete_endorsement/2" do
    setup do
      endorser = insert(:user, email_confirmed?: true)
      user_tag = insert(:user_tag, user: insert(:user), tag: insert(:tag))
      %{endorser: endorser, user_tag: user_tag}
    end

    test "endorsed?/2 reflects whether the row exists", ctx do
      refute Tags.endorsed?(ctx.user_tag.id, ctx.endorser.id)
      insert(:user_tag_endorsement, user_tag: ctx.user_tag, user: ctx.endorser)
      assert Tags.endorsed?(ctx.user_tag.id, ctx.endorser.id)
    end

    test "delete_endorsement/2 removes the endorser's row and is idempotent", ctx do
      insert(:user_tag_endorsement, user_tag: ctx.user_tag, user: ctx.endorser)

      assert Tags.delete_endorsement(ctx.user_tag.id, ctx.endorser.id) == 1
      refute Tags.endorsed?(ctx.user_tag.id, ctx.endorser.id)
      # Deleting again is a no-op, never a raise.
      assert Tags.delete_endorsement(ctx.user_tag.id, ctx.endorser.id) == 0
    end
  end

  describe "honor tags" do
    # A tag flagged honor? is reserved site-wide: a member can neither
    # self-assign nor self-remove it, and it is not endorsable. Only the admin
    # chokepoints (admin_assign_tag/2, admin_unassign_tag/2) touch the roster.

    test "add_user_tag/2 refuses a reserved (honor) tag" do
      user = insert(:user)
      name = unique_tag_name("vutuv_developer")
      insert(:tag, name: name, slug: name, honor?: true)

      assert {:error, changeset} = Tags.add_user_tag(user, name)
      assert %{tag_id: [_ | _]} = errors_on(changeset)
      # Nothing was inserted for this member.
      refute Repo.exists?(from(ut in UserTag, where: ut.user_id == ^user.id))
    end

    test "add_user_tag/2 refuses a reserved tag matched case-insensitively" do
      user = insert(:user)
      name = unique_tag_name("vutuv_developer")
      insert(:tag, name: name, slug: name, honor?: true)

      assert {:error, _changeset} = Tags.add_user_tag(user, String.upcase(name))
      refute Repo.exists?(from(ut in UserTag, where: ut.user_id == ^user.id))
    end

    test "add_user_tag/2 still links a normal (not honor) existing tag" do
      user = insert(:user)
      name = unique_tag_name("Elixir")
      tag = insert(:tag, name: name, slug: String.downcase(name))

      assert {:ok, user_tag} = Tags.add_user_tag(user, String.downcase(name))
      assert user_tag.tag_id == tag.id
    end

    test "admin_assign_tag/2 assigns an honor tag to a member" do
      user = insert(:user)
      tag = insert(:tag, honor?: true)

      assert {:ok, user_tag} = Tags.admin_assign_tag(tag, user)
      assert user_tag.user_id == user.id
      assert user_tag.tag_id == tag.id
    end

    test "admin_assign_tag/2 a second time returns the composite-unique error" do
      user = insert(:user)
      tag = insert(:tag, honor?: true)

      assert {:ok, _} = Tags.admin_assign_tag(tag, user)
      assert {:error, changeset} = Tags.admin_assign_tag(tag, user)
      assert %{user_id_tag_id: ["You already have this tag."]} = errors_on(changeset)
    end

    test "admin_unassign_tag/2 removes the assignment and is idempotent" do
      user = insert(:user)
      tag = insert(:tag, honor?: true)
      insert(:user_tag, user: user, tag: tag)

      assert Tags.admin_unassign_tag(tag, user) == 1
      assert Tags.admin_unassign_tag(tag, user) == 0
    end

    test "delete_user_tag/1 refuses an honor tag but deletes a normal one" do
      user = insert(:user)
      managed = insert(:user_tag, user: user, tag: insert(:tag, honor?: true))
      normal = insert(:user_tag, user: user, tag: insert(:tag))

      assert {:error, :honor} = Tags.delete_user_tag(managed)
      assert Repo.get(UserTag, managed.id)

      assert {:ok, _} = Tags.delete_user_tag(normal)
      refute Repo.get(UserTag, normal.id)
    end

    test "create_endorsement/1 refuses an honor tag" do
      endorser = insert(:user, email_confirmed?: true)
      user_tag = insert(:user_tag, user: insert(:user), tag: insert(:tag, honor?: true))

      assert {:error, _} =
               Tags.create_endorsement(%{user_id: endorser.id, user_tag_id: user_tag.id})

      refute Tags.endorsed?(user_tag.id, endorser.id)
    end

    test "honor_tags/0 lists honor tags with holder counts, name-ordered" do
      alpha = insert(:tag, name: "Alpha", slug: "alpha", honor?: true)
      _beta = insert(:tag, name: "Beta", slug: "beta", honor?: true)
      _normal = insert(:tag, name: "Gamma", slug: "gamma")
      insert(:user_tag, user: insert(:user), tag: alpha)
      insert(:user_tag, user: insert(:user), tag: alpha)

      assert [{%{name: "Alpha"}, 2}, {%{name: "Beta"}, 0}] = Tags.honor_tags()
    end

    test "honor_tags_count/0 counts only honor tags" do
      insert(:tag, honor?: true)
      insert(:tag, honor?: true)
      insert(:tag)

      assert Tags.honor_tags_count() == 2
    end

    test "declare_honor_tag/1 creates a brand-new honor tag" do
      assert {:ok, tag} = Tags.declare_honor_tag("vutuv_contributor")
      assert tag.honor?
      assert tag.name == "vutuv_contributor"
      assert tag.slug == "vutuv-contributor"
    end

    test "declare_honor_tag/1 flips an existing holder-less tag" do
      name = unique_tag_name("mentor")
      existing = insert(:tag, name: name, slug: name)

      assert {:ok, tag} = Tags.declare_honor_tag(String.capitalize(name))
      assert tag.id == existing.id
      assert tag.honor?
    end

    test "declare_honor_tag/1 is idempotent on an existing honor tag" do
      name = unique_tag_name("mentor")
      existing = insert(:tag, name: name, slug: name, honor?: true)

      assert {:ok, tag} = Tags.declare_honor_tag(name)
      assert tag.id == existing.id
    end

    test "declare_honor_tag/1 refuses to silently flip a tag members already hold" do
      name = unique_tag_name("elixir")
      existing = insert(:tag, name: name, slug: name)
      insert(:user_tag, user: insert(:user), tag: existing)

      assert {:error, :has_holders, tag} = Tags.declare_honor_tag(name)
      assert tag.id == existing.id
      refute Repo.reload(existing).honor?
    end

    test "declare_honor_tag/1 rejects a spaced name" do
      assert {:error, changeset} = Tags.declare_honor_tag("core team")
      refute changeset.valid?
    end

    test "tag_holders/1 lists the members carrying the tag" do
      tag = insert(:tag, honor?: true)
      alice = insert(:user, first_name: "Alice", last_name: "Adams")
      bob = insert(:user, first_name: "Bob", last_name: "Baker")
      _other = insert(:user)
      insert(:user_tag, user: alice, tag: tag)
      insert(:user_tag, user: bob, tag: tag)

      ids = tag |> Tags.tag_holders() |> Enum.map(& &1.id)
      assert alice.id in ids
      assert bob.id in ids
      assert length(ids) == 2
    end

    test "ordered_by_endorsements/0 sorts honor tags first, ahead of the most-endorsed tag" do
      owner = insert(:user, email_confirmed?: true)

      # A self-assigned tag with several visible endorsements.
      popular = insert(:user_tag, user: owner, tag: insert(:tag))

      for _ <- 1..3 do
        insert(:user_tag_endorsement,
          user_tag: popular,
          user: insert(:user, email_confirmed?: true)
        )
      end

      # An honor tag is never endorsable, so its count is 0; it must still lead.
      honor =
        insert(:user_tag,
          user: owner,
          tag: insert(:tag, honor?: true)
        )

      ordered =
        UserTag.ordered_by_endorsements()
        |> where(user_id: ^owner.id)
        |> Repo.all()

      assert Enum.map(ordered, & &1.id) == [honor.id, popular.id]
    end
  end

  describe "user_tag_endorsements" do
    test "create_endorsement/1 creates an endorsement" do
      user = insert(:user)
      tag_owner = insert(:user)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: tag_owner, tag: tag)

      assert {:ok, endorsement} =
               Tags.create_endorsement(%{user_id: user.id, user_tag_id: user_tag.id})

      assert endorsement.user_id == user.id
      assert endorsement.user_tag_id == user_tag.id
    end

    test "create_endorsement/1 pushes a live notification to the tag's owner" do
      endorser = insert(:user, first_name: "Ada", last_name: "Lovelace")
      tag_owner = insert(:user)
      tag = insert(:tag, name: "Phoenix")
      user_tag = insert(:user_tag, user: tag_owner, tag: tag)

      Vutuv.Activity.subscribe(tag_owner.id)

      assert {:ok, _} = Tags.create_endorsement(%{user_id: endorser.id, user_tag_id: user_tag.id})

      assert_receive {:new_notification,
                      %{kind: "endorsement", tag: "Phoenix", actor_name: "Ada Lovelace"} = n}

      assert n.actor_param == endorser.username
    end

    test "create_endorsement/1 does not notify on a self-endorsement" do
      tag_owner = insert(:user)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: tag_owner, tag: tag)

      Vutuv.Activity.subscribe(tag_owner.id)

      assert {:ok, _} =
               Tags.create_endorsement(%{user_id: tag_owner.id, user_tag_id: user_tag.id})

      refute_receive {:new_notification, _}
    end
  end

  # Issue #847: the one-time cleanup that reconciles legacy spaced tag names
  # with the no-space rule without underscoring legitimate multi-word names.
  describe "normalize_legacy_tag_whitespace/0" do
    defp holds?(user, tag_id) do
      Repo.exists?(from(ut in UserTag, where: ut.user_id == ^user.id and ut.tag_id == ^tag_id))
    end

    test "merges a whitespace-junk duplicate into the clean tag, moving holders" do
      clean = insert(:tag, name: "Datacenter", slug: "datacenter")
      junk = insert(:tag, name: " Datacenter", slug: "datacenter_2")
      keep_user = insert(:user)
      move_user = insert(:user)
      insert(:user_tag, user: keep_user, tag: clean)
      insert(:user_tag, user: move_user, tag: junk)

      assert {1, _} = Tags.normalize_legacy_tag_whitespace()

      # The junk tag is gone and everyone who held it now holds the clean one.
      refute Repo.get(Tag, junk.id)
      assert Repo.get(Tag, clean.id).name == "Datacenter"
      assert holds?(keep_user, clean.id)
      assert holds?(move_user, clean.id)
    end

    test "keeps the more-held pretty name even when the sibling is spaceless" do
      # "Phoenix Framework" (53 holders in prod) must win over a stray
      # "phoenix_framework" (1 holder), so the survivor keeps the readable name.
      pretty = insert(:tag, name: "Phoenix Framework", slug: "phoenix_framework")
      spaceless = insert(:tag, name: "phoenix_framework", slug: "phoenix_framework_2")
      for _ <- 1..3, do: insert(:user_tag, user: insert(:user), tag: pretty)
      insert(:user_tag, user: insert(:user), tag: spaceless)

      assert {1, _} = Tags.normalize_legacy_tag_whitespace()

      assert Repo.get(Tag, pretty.id).name == "Phoenix Framework"
      refute Repo.get(Tag, spaceless.id)
    end

    test "dedupes a member who holds both sides and moves their endorsements" do
      clean = insert(:tag, name: "Docker", slug: "docker")
      junk = insert(:tag, name: " Docker", slug: "docker_2")

      both = insert(:user)
      clean_ut = insert(:user_tag, user: both, tag: clean)
      junk_ut = insert(:user_tag, user: both, tag: junk)

      # An endorser who only endorses the junk side must survive the merge.
      endorser = insert(:user)
      insert(:user_tag_endorsement, user_tag: junk_ut, user: endorser)

      assert {1, _} = Tags.normalize_legacy_tag_whitespace()

      refute Repo.get(Tag, junk.id)
      # The member keeps exactly one user_tag for the survivor (no unique-index
      # violation), and the endorsement rode across onto it.
      assert holds?(both, clean.id)
      refute Repo.get(UserTag, junk_ut.id)

      assert Repo.exists?(
               from(e in UserTagEndorsement,
                 where: e.user_tag_id == ^clean_ut.id and e.user_id == ^endorser.id
               )
             )
    end

    test "trims stray whitespace from a non-colliding name, keeping the words" do
      tag = insert(:tag, name: " performance testing ", slug: "performance_testing")

      assert {0, 1} = Tags.normalize_legacy_tag_whitespace()

      assert Repo.get(Tag, tag.id).name == "performance testing"
    end

    test "leaves a clean multi-word name untouched and is idempotent" do
      name = unique_tag_name("Ruby on Rails")
      tag = insert(:tag, name: name, slug: name |> String.downcase() |> String.replace(" ", "_"))

      assert {0, 0} = Tags.normalize_legacy_tag_whitespace()
      assert Repo.get(Tag, tag.id).name == name

      # A second pass finds nothing to do.
      assert {0, 0} = Tags.normalize_legacy_tag_whitespace()
    end

    test "merges a sibling pair that has no pre-existing clean tag" do
      # "sap basis" (7 holders) + " sap basis" (1) with no clean "sap_basis":
      # keep the better-held one, drop the twin.
      keep = insert(:tag, name: "sap basis", slug: "sap_basis")
      twin = insert(:tag, name: " sap basis", slug: "sap_basis_2")
      insert(:user_tag, user: insert(:user), tag: keep)
      insert(:user_tag, user: insert(:user), tag: twin)

      assert {1, _} = Tags.normalize_legacy_tag_whitespace()

      assert Repo.get(Tag, keep.id).name == "sap basis"
      refute Repo.get(Tag, twin.id)
    end
  end

  describe "tag follows (issue #872)" do
    test "follow_tag/2 subscribes a member to a tag" do
      user = insert(:user)
      tag = insert(:tag)

      assert {:ok, %TagFollow{} = follow} = Tags.follow_tag(user, tag)
      assert follow.user_id == user.id
      assert follow.tag_id == tag.id
      assert Tags.tag_followed?(user, tag)
    end

    test "follow_tag/2 is idempotent — a double follow keeps one row and still returns ok" do
      user = insert(:user)
      tag = insert(:tag)

      assert {:ok, _} = Tags.follow_tag(user, tag)
      assert {:ok, %TagFollow{}} = Tags.follow_tag(user, tag)

      assert Repo.aggregate(from(tf in TagFollow, where: tf.user_id == ^user.id), :count) == 1
    end

    test "follow_tag/2 broadcasts :tag_follows_changed on the follower's topic" do
      user = insert(:user)
      tag = insert(:tag)
      Vutuv.Activity.subscribe(user.id)

      assert {:ok, _} = Tags.follow_tag(user, tag)
      assert_receive {:tag_follows_changed, _}
    end

    test "unfollow_tag/2 removes the subscription (by %Tag{} and by id), idempotently" do
      user = insert(:user)
      tag = insert(:tag)
      Tags.follow_tag(user, tag)

      assert Tags.unfollow_tag(user, tag) == 1
      refute Tags.tag_followed?(user, tag)
      # A second unfollow (already gone) is a no-op, not a raise.
      assert Tags.unfollow_tag(user, tag.id) == 0
    end

    test "unfollow_tag/2 ignores a non-UUID id without raising" do
      user = insert(:user)
      assert Tags.unfollow_tag(user, "not-a-uuid") == 0
    end

    test "followed_tags/1 lists the member's tags, most-recently-followed first" do
      user = insert(:user)
      first = insert(:tag)
      second = insert(:tag)
      Tags.follow_tag(user, first)
      Tags.follow_tag(user, second)

      assert [t1, t2] = Tags.followed_tags(user)
      assert t1.id == second.id
      assert t2.id == first.id
    end

    test "followed_tag_ids/1 returns the followed tag ids (by user or by id)" do
      user = insert(:user)
      tag = insert(:tag)
      Tags.follow_tag(user, tag)

      assert Tags.followed_tag_ids(user) == [tag.id]
      assert Tags.followed_tag_ids(user.id) == [tag.id]
    end

    test "tag_follower_count/1 counts the tag's followers" do
      tag = insert(:tag)
      for _ <- 1..3, do: Tags.follow_tag(insert(:user), tag)
      assert Tags.tag_follower_count(tag) == 3
    end

    test "people_for_followed_tags/1 ranks visible members endorsed for followed tags, minus self" do
      viewer = insert(:user, email_confirmed?: true)
      tag = insert(:tag)
      Tags.follow_tag(viewer, tag)

      popular = insert(:user, email_confirmed?: true)
      quiet = insert(:user, email_confirmed?: true)
      popular_ut = insert(:user_tag, user: popular, tag: tag)
      insert(:user_tag, user: quiet, tag: tag)

      for _ <- 1..2,
          do:
            insert(:user_tag_endorsement,
              user_tag: popular_ut,
              user: insert(:user, email_confirmed?: true)
            )

      # The viewer also carries the tag but must never be suggested to themselves.
      insert(:user_tag, user: viewer, tag: tag)

      ids = viewer |> Tags.people_for_followed_tags(10) |> Enum.map(& &1.id)

      refute viewer.id in ids
      assert popular.id in ids
      assert quiet.id in ids
      # Most-endorsed leads.
      assert hd(ids) == popular.id
    end

    test "people_for_followed_tags/1 is empty when the member follows no tags" do
      assert Tags.people_for_followed_tags(insert(:user), 10) == []
    end
  end
end
