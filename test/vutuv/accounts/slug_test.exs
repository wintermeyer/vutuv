defmodule Vutuv.Accounts.SlugTest do
  @moduledoc """
  The username (@handle) rules. A handle follows the Twitter username
  mechanism: letters, digits and underscores only, at most 15 characters
  (minimum 3), stored lowercase, unique (one live handle per member), and
  never a reserved route word. There is no slugs table anymore: changing the
  handle simply renames the account - the old name is freed for anyone else
  and does not redirect. Changes are rate-limited via the `slug_changes`
  ledger: at most 4 changes within a rolling 90-day window.
  """
  use Vutuv.DataCase

  alias Vutuv.Accounts
  alias Vutuv.Accounts.ReservedSlugs
  alias Vutuv.Accounts.SlugChange
  alias Vutuv.Accounts.User

  defp slug_changeset(value) do
    User.slug_changeset(%User{}, %{"active_slug" => value})
  end

  defp days_ago(days) do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-round(days * 86_400), :second)
    |> NaiveDateTime.truncate(:second)
  end

  describe "Twitter-style validation (User.slug_changeset/2)" do
    test "accepts letters, digits and underscores, 3 to 15 characters" do
      for value <- ["abc", "stefan_w99", "_x_", "a23456789012345"] do
        assert slug_changeset(value).valid?, "expected #{value} to be accepted"
      end
    end

    test "rejects dots, dashes, spaces and other non-word characters" do
      for value <- ["jane.doe", "jane-doe", "jane doe", "jäne", "jane!", "@jane"] do
        changeset = slug_changeset(value)
        refute changeset.valid?, "expected #{value} to be rejected"

        assert "may only contain letters, numbers, and underscores" in errors_on(changeset).active_slug
      end
    end

    test "rejects too short, too long, and blank values" do
      refute slug_changeset("ab").valid?
      refute slug_changeset(String.duplicate("a", 16)).valid?

      changeset = slug_changeset("")
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).active_slug
    end

    test "uppercase input is stored lowercase (handles are case-insensitive)" do
      changeset = slug_changeset("Stefan_W")
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :active_slug) == "stefan_w"
    end

    test "route and asset path words cannot be claimed as usernames" do
      # Profiles live at the URL root, so a handle equal to a route prefix
      # would shadow that route forever.
      for value <- ["tags", "login", "messages", "assets", "users"] do
        changeset = slug_changeset(value)
        refute changeset.valid?, "expected #{value} to be rejected"
        assert "is reserved" in errors_on(changeset).active_slug
      end
    end
  end

  describe "generated handles (registration)" do
    test "names slugify to underscore-style handles" do
      user = %User{first_name: "Jane Maria", last_name: "Doe"}

      assert Vutuv.SlugHelpers.gen_handle_unique(user, User, :active_slug) == "jane_maria_doe"
    end

    test "generated handles never exceed 15 characters" do
      user = %User{first_name: "Maximiliane", last_name: "Wintermeyer"}

      handle = Vutuv.SlugHelpers.gen_handle_unique(user, User, :active_slug)
      assert String.length(handle) <= 15
      assert slug_changeset(handle).valid?
    end

    test "reserved words come out suffixed, still within 15 characters" do
      reserved = ReservedSlugs.list()
      user = %User{first_name: "Login", last_name: nil}

      handle = Vutuv.SlugHelpers.gen_handle_unique(user, User, :active_slug, reserved)

      assert handle =~ ~r/^login_[0-9a-f]{8}$/
      refute handle in reserved
    end

    test "a taken handle gets a suffix and stays within 15 characters" do
      insert(:user, active_slug: "jane_maria_doe")
      user = %User{first_name: "Jane Maria", last_name: "Doe"}

      handle = Vutuv.SlugHelpers.gen_handle_unique(user, User, :active_slug)

      assert handle =~ ~r/^jane_m_[0-9a-f]{8}$/
      assert String.length(handle) <= 15
    end

    test "registration around a reserved name still succeeds" do
      # register_user/2 generates the handle from the name; "Tags" slugifies to
      # the reserved word "tags" and must come out suffixed, not rejected.
      conn = %Plug.Conn{assigns: %{locale: "en"}}

      {:ok, user} =
        Vutuv.Accounts.register_user(conn, %{
          "first_name" => "Tags",
          "emails" => %{"0" => %{"value" => "tags@example.com"}}
        })

      assert user.active_slug =~ ~r/^tags_[0-9a-f]{8}$/
    end
  end

  describe "update_active_slug/2" do
    test "renames the account and logs the change in the ledger" do
      user = insert_activated_user()

      assert {:ok, %User{} = updated} =
               Accounts.update_active_slug(user, %{"active_slug" => "Fresh_Handle"})

      assert updated.active_slug == "fresh_handle"

      assert [%SlugChange{value: "fresh_handle"}] =
               Repo.all(from(c in SlugChange, where: c.user_id == ^user.id))
    end

    test "the old handle is freed: anyone else can claim it right away" do
      user = insert_activated_user(active_slug: "first_owner")
      old_handle = user.active_slug
      {:ok, _} = Accounts.update_active_slug(user, %{"active_slug" => "moved_away"})

      other = insert_activated_user()

      assert {:ok, %User{active_slug: ^old_handle}} =
               Accounts.update_active_slug(other, %{"active_slug" => old_handle})
    end

    test "an invalid handle returns the changeset and changes nothing" do
      user = insert_activated_user()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_active_slug(user, %{"active_slug" => "not valid!"})

      assert Repo.get(User, user.id).active_slug == user.active_slug
      assert Repo.aggregate(SlugChange, :count) == 0
    end

    test "a handle in use by someone else returns the changeset" do
      insert(:user, active_slug: "wanted_handle")
      user = insert_activated_user()

      assert {:error, changeset} =
               Accounts.update_active_slug(user, %{"active_slug" => "wanted_handle"})

      assert "has already been taken" in errors_on(changeset).active_slug
    end

    test "re-submitting the current handle is rejected, not silently logged" do
      user = insert_activated_user()

      assert {:error, changeset} =
               Accounts.update_active_slug(user, %{"active_slug" => user.active_slug})

      assert "is already your username" in errors_on(changeset).active_slug
      assert Repo.aggregate(SlugChange, :count) == 0
    end
  end

  describe "the change quota (4 per rolling 90 days)" do
    test "a fresh account has the full quota" do
      user = insert_activated_user()

      assert %{used: 0, remaining: 4, limit: 4, window_days: 90, next_change_at: nil} =
               Accounts.slug_change_quota(user)
    end

    test "each change consumes quota; the fifth within the window is refused" do
      user = insert_activated_user()

      for n <- 1..4 do
        assert {:ok, _} = Accounts.update_active_slug(user, %{"active_slug" => "handle_#{n}"})
      end

      quota = Accounts.slug_change_quota(user)
      assert quota.remaining == 0
      assert quota.next_change_at != nil

      assert {:error, changeset} =
               Accounts.update_active_slug(user, %{"active_slug" => "handle_5"})

      assert "can only be changed 4 times within 90 days" in errors_on(changeset).active_slug
    end

    test "changes older than 90 days no longer count" do
      user = insert_activated_user()

      for days <- [120, 100, 95, 91] do
        insert(:slug_change, user: user, inserted_at: days_ago(days))
      end

      assert %{used: 0, remaining: 4} = Accounts.slug_change_quota(user)
    end

    test "next_change_at is when the oldest counted change leaves the window" do
      user = insert_activated_user()
      oldest = days_ago(80)

      insert(:slug_change, user: user, inserted_at: oldest)

      for days <- [50, 20, 5] do
        insert(:slug_change, user: user, inserted_at: days_ago(days))
      end

      quota = Accounts.slug_change_quota(user)
      assert quota.used == 4
      assert quota.remaining == 0

      assert NaiveDateTime.compare(quota.next_change_at, NaiveDateTime.add(oldest, 90 * 86_400)) ==
               :eq
    end
  end

  describe "slug_taken?/1" do
    test "knows which handles are in use right now" do
      insert(:user, active_slug: "claimed_handle")

      assert Accounts.slug_taken?("claimed_handle")
      refute Accounts.slug_taken?("free_handle")
    end
  end
end
