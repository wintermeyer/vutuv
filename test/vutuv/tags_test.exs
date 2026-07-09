defmodule Vutuv.TagsTest do
  use Vutuv.DataCase

  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
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
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      changeset = link("elixir")
      assert get_change(changeset, :tag_id) == tag.id
    end

    test "builds a new tag when no name or slug matches" do
      changeset = link("Rust")
      refute get_change(changeset, :tag_id)
      built = get_change(changeset, :tag)
      assert get_change(built, :name) == "Rust"
      assert get_change(built, :slug) =~ "rust"
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

    test "a value with whitespace is never linked to a legacy multi-word tag" do
      # A legacy tag from before the no-space rule still exists; a spaced value
      # must not attach it. It builds a fresh (invalid) tag instead, so the
      # changeset fails validation rather than quietly linking the old tag.
      insert(:tag, name: "Ruby on Rails", slug: "ruby-on-rails")

      changeset = link("Ruby on Rails")
      refute get_change(changeset, :tag_id)
      assert get_change(changeset, :tag)
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
      tag = insert(:tag, name: "elixir", slug: "elixir")

      assert {:ok, updated} = tag |> Tag.edit_changeset(%{"name" => "Elixir"}) |> Repo.update()
      assert updated.name == "Elixir"
    end
  end

  describe "parse_tag_names/1" do
    test "splits on both commas and spaces" do
      assert Tags.parse_tag_names("Elixir, Phoenix Go") == ["Elixir", "Phoenix", "Go"]
    end

    test "splits what used to be one multi-word tag into one tag per word" do
      assert Tags.parse_tag_names("Ruby on Rails") == ["Ruby", "on", "Rails"]
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
      tag = insert(:tag, name: "Elixir", slug: "elixir")

      changeset =
        %UserTag{} |> change(%{}) |> Tag.create_or_link_tag(%{"value" => "#Elixir"})

      assert get_change(changeset, :tag_id) == tag.id
    end

    test "add_user_tag stores #elixir as the tag elixir" do
      user = insert(:user)

      assert {:ok, user_tag} = Tags.add_user_tag(user, "#elixir")
      tag = Repo.preload(user_tag, :tag).tag
      assert tag.name == "elixir"
      assert tag.slug == "elixir"
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

  describe "add_user_tag/2 rejects spaces" do
    test "a spaced name that is not an existing tag fails validation" do
      user = insert(:user)

      assert {:error, changeset} = Tags.add_user_tag(user, "Ruby on Rails")
      assert %{tag: %{name: ["must not contain spaces"]}} = errors_on(changeset)
    end

    test "a single-word name is stored" do
      user = insert(:user)

      assert {:ok, user_tag} = Tags.add_user_tag(user, "Elixir")
      assert Repo.preload(user_tag, :tag).tag.name == "Elixir"
    end
  end

  describe "user_tags" do
    test "UserTag.name/1 returns the tag's name" do
      user = insert(:user)
      tag = insert(:tag, name: "Elixir")
      user_tag = insert(:user_tag, user: user, tag: tag)
      assert UserTag.name(user_tag) == "Elixir"
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
      insert(:tag, name: "vutuv_developer", slug: "vutuv_developer", honor?: true)

      assert {:error, changeset} = Tags.add_user_tag(user, "vutuv_developer")
      assert %{tag_id: [_ | _]} = errors_on(changeset)
      # Nothing was inserted for this member.
      refute Repo.exists?(from(ut in UserTag, where: ut.user_id == ^user.id))
    end

    test "add_user_tag/2 refuses a reserved tag matched case-insensitively" do
      user = insert(:user)
      insert(:tag, name: "vutuv_developer", slug: "vutuv_developer", honor?: true)

      assert {:error, _changeset} = Tags.add_user_tag(user, "Vutuv_Developer")
      refute Repo.exists?(from(ut in UserTag, where: ut.user_id == ^user.id))
    end

    test "add_user_tag/2 still links a normal (not honor) existing tag" do
      user = insert(:user)
      tag = insert(:tag, name: "Elixir", slug: "elixir")

      assert {:ok, user_tag} = Tags.add_user_tag(user, "elixir")
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
      existing = insert(:tag, name: "mentor", slug: "mentor")

      assert {:ok, tag} = Tags.declare_honor_tag("Mentor")
      assert tag.id == existing.id
      assert tag.honor?
    end

    test "declare_honor_tag/1 is idempotent on an existing honor tag" do
      existing = insert(:tag, name: "mentor", slug: "mentor", honor?: true)

      assert {:ok, tag} = Tags.declare_honor_tag("mentor")
      assert tag.id == existing.id
    end

    test "declare_honor_tag/1 refuses to silently flip a tag members already hold" do
      existing = insert(:tag, name: "elixir", slug: "elixir")
      insert(:user_tag, user: insert(:user), tag: existing)

      assert {:error, :has_holders, tag} = Tags.declare_honor_tag("elixir")
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
      popular = insert(:user_tag, user: owner, tag: insert(:tag, name: "Elixir", slug: "elixir"))

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
          tag: insert(:tag, name: "Vutuv Developer", slug: "vutuv_developer", honor?: true)
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
      tag = insert(:tag, name: "Ruby on Rails", slug: "ruby_on_rails")

      assert {0, 0} = Tags.normalize_legacy_tag_whitespace()
      assert Repo.get(Tag, tag.id).name == "Ruby on Rails"

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
end
