defmodule Vutuv.Accounts.SlugTest do
  @moduledoc """
  The username (@handle) rules. A handle follows the Twitter username
  mechanism: letters, digits and underscores only, at most 15 characters
  (minimum 3), stored lowercase, unique (one live handle per member), and
  never a reserved route word. There is no slugs table anymore: changing the
  handle simply renames the account - the old name is freed for anyone else
  and does not redirect. Changes are rate-limited via the `username_changes`
  ledger: at most 4 changes within a rolling 90-day window.
  """
  use Vutuv.DataCase

  alias Vutuv.Accounts
  alias Vutuv.Accounts.ReservedSlugs
  alias Vutuv.Accounts.User
  alias Vutuv.Accounts.UsernameChange

  defp username_changeset(value) do
    User.username_changeset(%User{}, %{"username" => value})
  end

  defp days_ago(days) do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-round(days * 86_400), :second)
    |> NaiveDateTime.truncate(:second)
  end

  describe "Twitter-style validation (User.username_changeset/2)" do
    test "accepts letters, digits and underscores, 3 to 15 characters" do
      for value <- ["abc", "stefan_w99", "_x_", "a23456789012345"] do
        assert username_changeset(value).valid?, "expected #{value} to be accepted"
      end
    end

    test "rejects dots, dashes, spaces and other non-word characters" do
      for value <- ["jane.doe", "jane-doe", "jane doe", "jäne", "jane!", "@jane"] do
        changeset = username_changeset(value)
        refute changeset.valid?, "expected #{value} to be rejected"

        assert "may only contain letters, numbers, and underscores" in errors_on(changeset).username
      end
    end

    test "rejects too short, too long, and blank values" do
      refute username_changeset("ab").valid?
      refute username_changeset(String.duplicate("a", 16)).valid?

      changeset = username_changeset("")
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).username
    end

    test "uppercase input is stored lowercase (handles are case-insensitive)" do
      changeset = username_changeset("Stefan_W")
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :username) == "stefan_w"
    end

    test "route and asset path words cannot be claimed as usernames" do
      # Profiles live at the URL root, so a handle equal to a route prefix
      # would shadow that route forever. The underscore words are real route
      # prefixes too: handles allow underscores (^[a-z0-9_]+$), so any route
      # word of 3-15 characters must be reserved regardless of underscores.
      for value <- [
            "tags",
            "login",
            "messages",
            # The whole user-agnostic editing scope (v7.35.0) hangs off this
            # one word - a member named "settings" must stay impossible.
            "settings",
            "assets",
            "users",
            "username",
            "benutzername",
            "unsubscribe",
            "post_images",
            "follow_back",
            "search_queries",
            "sent_emails"
          ] do
        changeset = username_changeset(value)
        refute changeset.valid?, "expected #{value} to be rejected"
        assert "is reserved" in errors_on(changeset).username
      end
    end
  end

  describe "generated handles (registration)" do
    test "names slugify to underscore-style handles" do
      user = %User{first_name: "Jane Maria", last_name: "Doe"}

      assert Vutuv.SlugHelpers.gen_handle_unique(user, User, :username) == "jane_maria_doe"
    end

    test "umlauts and ß transliterate instead of vanishing" do
      # "Paula Prüfer" used to come out as "paula_prfer" - the umlaut was
      # stripped, mangling the name. German specials map to their
      # two-letter forms, other diacritics to their base letter.
      assert handle_for("Paula", "Prüfer") == "paula_pruefer"
      assert handle_for("Jörg", "Weiß") == "joerg_weiss"
      assert handle_for("Älva", nil) == "aelva"
      assert handle_for("André", "Çelik") == "andre_celik"
    end

    defp handle_for(first, last) do
      user = %User{first_name: first, last_name: last}
      Vutuv.SlugHelpers.gen_handle_unique(user, User, :username)
    end

    test "generated handles never exceed 15 characters" do
      user = %User{first_name: "Maximiliane", last_name: "Wintermeyer"}

      handle = Vutuv.SlugHelpers.gen_handle_unique(user, User, :username)
      assert String.length(handle) <= 15
      assert username_changeset(handle).valid?
    end

    test "reserved words come out suffixed, still within 15 characters" do
      reserved = ReservedSlugs.list()
      user = %User{first_name: "Login", last_name: nil}

      handle = Vutuv.SlugHelpers.gen_handle_unique(user, User, :username, reserved)

      assert handle =~ ~r/^login_[0-9a-f]{8}$/
      refute handle in reserved
    end

    test "a taken handle gets a suffix and stays within 15 characters" do
      insert(:user, username: "jane_maria_doe")
      user = %User{first_name: "Jane Maria", last_name: "Doe"}

      handle = Vutuv.SlugHelpers.gen_handle_unique(user, User, :username)

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
          "emails" => %{"0" => %{"value" => "tags@example.com"}},
          "tag_list" => "Elixir Cooking Origami"
        })

      assert user.username =~ ~r/^tags_[0-9a-f]{8}$/
    end
  end

  describe "update_username/2" do
    test "renames the account and logs the change in the ledger" do
      user = insert_activated_user()

      assert {:ok, %User{} = updated} =
               Accounts.update_username(user, %{"username" => "Fresh_Handle"})

      assert updated.username == "fresh_handle"

      assert [%UsernameChange{value: "fresh_handle"}] =
               Repo.all(from(c in UsernameChange, where: c.user_id == ^user.id))
    end

    test "the old handle is freed: anyone else can claim it right away" do
      user = insert_activated_user(username: "first_owner")
      old_handle = user.username
      {:ok, _} = Accounts.update_username(user, %{"username" => "moved_away"})

      other = insert_activated_user()

      assert {:ok, %User{username: ^old_handle}} =
               Accounts.update_username(other, %{"username" => old_handle})
    end

    test "an invalid handle returns the changeset and changes nothing" do
      user = insert_activated_user()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_username(user, %{"username" => "not valid!"})

      assert Repo.get(User, user.id).username == user.username
      assert Repo.aggregate(UsernameChange, :count) == 0
    end

    test "a handle in use by someone else returns the changeset" do
      insert(:user, username: "wanted_handle")
      user = insert_activated_user()

      assert {:error, changeset} =
               Accounts.update_username(user, %{"username" => "wanted_handle"})

      assert "has already been taken" in errors_on(changeset).username
    end

    test "re-submitting the current handle is rejected, not silently logged" do
      user = insert_activated_user()

      assert {:error, changeset} =
               Accounts.update_username(user, %{"username" => user.username})

      assert "is already your username" in errors_on(changeset).username
      assert Repo.aggregate(UsernameChange, :count) == 0
    end
  end

  describe "the change quota (4 per rolling 90 days)" do
    test "a fresh account has the full quota" do
      user = insert_activated_user()

      assert %{used: 0, remaining: 4, limit: 4, window_days: 90, next_change_at: nil} =
               Accounts.username_change_quota(user)
    end

    test "each change consumes quota; the fifth within the window is refused" do
      user = insert_activated_user()

      for n <- 1..4 do
        assert {:ok, _} = Accounts.update_username(user, %{"username" => "handle_#{n}"})
      end

      quota = Accounts.username_change_quota(user)
      assert quota.remaining == 0
      assert quota.next_change_at != nil

      assert {:error, changeset} =
               Accounts.update_username(user, %{"username" => "handle_5"})

      assert "can only be changed 4 times within 90 days" in errors_on(changeset).username
    end

    test "changes older than 90 days no longer count" do
      user = insert_activated_user()

      for days <- [120, 100, 95, 91] do
        insert(:username_change, user: user, inserted_at: days_ago(days))
      end

      assert %{used: 0, remaining: 4} = Accounts.username_change_quota(user)
    end

    test "next_change_at is when the oldest counted change leaves the window" do
      user = insert_activated_user()
      oldest = days_ago(80)

      insert(:username_change, user: user, inserted_at: oldest)

      for days <- [50, 20, 5] do
        insert(:username_change, user: user, inserted_at: days_ago(days))
      end

      quota = Accounts.username_change_quota(user)
      assert quota.used == 4
      assert quota.remaining == 0

      assert NaiveDateTime.compare(quota.next_change_at, NaiveDateTime.add(oldest, 90 * 86_400)) ==
               :eq
    end
  end

  describe "username_taken?/1" do
    test "knows which handles are in use right now" do
      insert(:user, username: "claimed_handle")

      assert Accounts.username_taken?("claimed_handle")
      refute Accounts.username_taken?("free_handle")
    end
  end
end
