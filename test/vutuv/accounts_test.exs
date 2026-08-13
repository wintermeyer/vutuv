defmodule Vutuv.AccountsTest do
  use Vutuv.DataCase

  alias Vutuv.Accounts
  alias Vutuv.Accounts.LoginPin
  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  @valid_registration %{
    "emails" => %{"0" => %{"value" => "test@example.com"}},
    "first_name" => "Test",
    "last_name" => "User",
    "tag_list" => "Elixir, Cooking, Origami"
  }

  defp build_conn do
    %Plug.Conn{
      assigns: %{locale: "en"},
      private: %{plug_session: %{}, plug_session_fetch: :done}
    }
    |> Plug.Test.init_test_session(%{})
  end

  # Moves a user's PIN's `minted_at` `seconds_ago` into the past so the
  # private `pin_expired?/1` threshold can be exercised without sleeping.
  defp backdate_pin(user, type, seconds_ago) do
    minted_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-seconds_ago, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.one(from(m in LoginPin, where: m.user_id == ^user.id and m.type == ^type))
    |> LoginPin.changeset(%{minted_at: minted_at})
    |> Repo.update!()
  end

  # Builds an account exactly as a sign-up does — user + a "login" PIN minted
  # alongside it — then ages both `minutes` into the past so the sweep threshold
  # can be exercised without sleeping.
  defp pending_registration(opts) do
    minutes = Keyword.get(opts, :age_minutes, 0)
    email_confirmed? = Keyword.get(opts, :email_confirmed?, false)

    user = insert(:user, email_confirmed?: email_confirmed?)
    Accounts.gen_pin_for(user, "login")
    set_inserted_at(from(u in User, where: u.id == ^user.id), minutes)
    set_inserted_at(from(p in LoginPin, where: p.user_id == ^user.id), minutes)
    user
  end

  defp set_inserted_at(query, minutes_ago) do
    ts =
      NaiveDateTime.utc_now(:second)
      |> NaiveDateTime.add(-minutes_ago * 60)

    Repo.update_all(query, set: [inserted_at: ts])
  end

  describe "register_user/2" do
    test "creates a user with valid attrs" do
      conn = build_conn()
      assert {:ok, %User{} = user} = Accounts.register_user(conn, @valid_registration)
      assert user.first_name == "Test"
      assert user.last_name == "User"
      assert user.username != nil
    end

    test "fails with missing name" do
      conn = build_conn()
      attrs = %{"emails" => %{"0" => %{"value" => "test@example.com"}}}
      assert {:error, _changeset} = Accounts.register_user(conn, attrs)
    end

    test "ignores an email_confirmed? flag smuggled into the params" do
      conn = build_conn()
      attrs = Map.put(@valid_registration, "email_confirmed?", "true")

      assert {:ok, %User{} = user} = Accounts.register_user(conn, attrs)
      refute user.email_confirmed?
    end

    # Tags are how members are found, so a sign-up must arrive with at least
    # three distinct ones. The minimum counts what actually lands as tags:
    # parsed like register_user parses them, duplicates (case-insensitively)
    # collapsed first.
    test "creates the tags alongside the user" do
      conn = build_conn()
      assert {:ok, %User{} = user} = Accounts.register_user(conn, @valid_registration)

      assert user.user_tags |> Enum.map(& &1.tag.name) |> Enum.sort() ==
               ["Cooking", "Elixir", "Origami"]
    end

    test "the multi-tag sign-up keeps the entered casing (never downcases)" do
      conn = build_conn()
      # Internal capitals a downcase would visibly destroy, entered as the
      # comma-separated batch the sign-up field accepts.
      attrs = Map.put(@valid_registration, "tag_list", "TypeScript, PostgreSQL, WebAssembly")

      assert {:ok, %User{} = user} = Accounts.register_user(conn, attrs)

      assert user.user_tags |> Enum.map(& &1.tag.name) |> Enum.sort() ==
               ["PostgreSQL", "TypeScript", "WebAssembly"]
    end

    test "a sign-up tag links to an existing tag, keeping the first writer's spelling" do
      # A legacy lowercase tag already exists; a member typing it capitalized at
      # sign-up attaches that same tag rather than minting a case-variant, so the
      # stored spelling stays what its first writer chose.
      insert(:tag, name: "elixir", slug: "elixir")
      conn = build_conn()

      assert {:ok, %User{} = user} =
               Accounts.register_user(
                 conn,
                 Map.put(@valid_registration, "tag_list", "Elixir, Cooking, Origami")
               )

      assert user.user_tags |> Enum.map(& &1.tag.name) |> Enum.sort() ==
               ["Cooking", "Origami", "elixir"]
    end

    test "rejects a registration with fewer than three tags" do
      conn = build_conn()
      attrs = Map.put(@valid_registration, "tag_list", "Elixir, Cooking")

      assert {:error, changeset} = Accounts.register_user(conn, attrs)
      assert "Please enter at least 3 different tags." in errors_on(changeset).tag_list
      refute Repo.get_by(User, first_name: "Test")
    end

    test "rejects a registration without any tags" do
      conn = build_conn()
      attrs = Map.delete(@valid_registration, "tag_list")

      assert {:error, changeset} = Accounts.register_user(conn, attrs)
      assert "Please enter at least 3 different tags." in errors_on(changeset).tag_list
    end

    test "a differently-cased duplicate counts as one tag" do
      conn = build_conn()
      attrs = Map.put(@valid_registration, "tag_list", "Elixir, elixir, ELIXIR, Cooking")

      assert {:error, changeset} = Accounts.register_user(conn, attrs)
      assert "Please enter at least 3 different tags." in errors_on(changeset).tag_list
    end

    test "rejects a registration over the tag ceiling" do
      conn = build_conn()
      max = Vutuv.Tags.max_user_tags()
      too_many = Enum.map_join(1..(max + 1), ", ", &"Skill#{&1}")
      attrs = Map.put(@valid_registration, "tag_list", too_many)

      assert {:error, changeset} = Accounts.register_user(conn, attrs)
      assert "Please enter at most #{max} different tags." in errors_on(changeset).tag_list
      refute Repo.get_by(User, first_name: "Test")
    end

    test "rejects a registration whose tag list holds a web address" do
      # register_user/3 materializes the tags after the insert and ignores
      # per-tag failures, so the form has to catch this up front — otherwise
      # the account is created with the tag silently missing.
      conn = build_conn()
      attrs = Map.put(@valid_registration, "tag_list", "Elixir, Cooking, www.example-shop.com")

      assert {:error, changeset} = Accounts.register_user(conn, attrs)

      assert "\"www.example-shop.com\" is a web address, not a tag. Please describe yourself with words." in errors_on(
               changeset
             ).tag_list

      refute Repo.get_by(User, first_name: "Test")
    end

    test "rejects a registration whose tag list holds a punctuation-only tag" do
      conn = build_conn()
      attrs = Map.put(@valid_registration, "tag_list", "Elixir, Kochen, ???")

      assert {:error, changeset} = Accounts.register_user(conn, attrs)

      assert "\"???\" is only punctuation, not a tag." in errors_on(changeset).tag_list

      refute Repo.get_by(User, first_name: "Test")
    end

    test "accepts a registration exactly at the tag ceiling" do
      conn = build_conn()
      max = Vutuv.Tags.max_user_tags()
      exactly = Enum.map_join(1..max, ", ", &"Skill#{&1}")
      attrs = Map.put(@valid_registration, "tag_list", exactly)

      assert {:ok, user} = Accounts.register_user(conn, attrs)
      assert length(user.user_tags) == max
    end
  end

  describe "update_user/2" do
    test "updates with valid attrs" do
      user = insert(:user)
      assert {:ok, updated} = Accounts.update_user(user, %{first_name: "Updated"})
      assert updated.first_name == "Updated"
    end

    test "ignores an email_confirmed? flag smuggled into the params" do
      user = insert(:user, email_confirmed?: false)

      assert {:ok, updated} =
               Accounts.update_user(user, %{
                 "first_name" => "Updated",
                 "email_confirmed?" => "true"
               })

      refute updated.email_confirmed?
    end

    test "rebuilds the people-search index when the name changes (API rename stays in sync)" do
      user = insert(:user, first_name: "Jane", last_name: "Doe")

      for cs <-
            SearchTerm.create_search_terms(%{
              "first_name" => "Jane",
              "last_name" => "Doe"
            }) do
        cs |> Ecto.Changeset.put_change(:user_id, user.id) |> Repo.insert!()
      end

      {:ok, _} = Accounts.update_user(user, %{"last_name" => "Smith"})

      terms =
        Repo.all(from(s in SearchTerm, where: s.user_id == ^user.id, select: s.value))
        |> Enum.map(&String.downcase/1)

      assert Enum.any?(terms, &String.contains?(&1, "smith"))
      refute Enum.any?(terms, &String.contains?(&1, "doe"))
    end

    test "a name change does not wipe the index when one name key is omitted" do
      user = insert(:user, first_name: "Jane", last_name: "Doe")

      {:ok, _} = Accounts.update_user(user, %{"first_name" => "Janet"})

      terms = Repo.all(from(s in SearchTerm, where: s.user_id == ^user.id))
      refute terms == []
    end

    # The tagline is the line under a member's name, so it must say something
    # about them: a bare URL there is a billboard (the "SBASF FC" sign-up), and
    # the profile is a member page, not a link farm.
    test "refuses a tagline that is nothing but a link" do
      user = insert(:user)

      for headline <- [
            "https://www.example-shop.com/",
            "www.example-shop.com",
            "example-shop.com",
            "[Cheap Slots](https://example-shop.com)",
            "kontakt@example-shop.com"
          ] do
        assert {:error, changeset} = Accounts.update_user(user, %{"headline" => headline})

        assert "can't be only a link. Please describe yourself in a few words." in errors_on(
                 changeset
               ).headline
      end
    end

    test "accepts a tagline that mentions a link inside a sentence" do
      user = insert(:user)
      headline = "Co-Founder of Example (www.example-shop.com)"

      assert {:ok, updated} = Accounts.update_user(user, %{"headline" => headline})
      assert updated.headline == headline
    end
  end

  # The spoken-name hint (issue #1112). Optional everywhere, so the interesting
  # cases are the empty one (stays absent, nothing renders) and the values that
  # pronounce nothing at all.
  describe "name pronunciation" do
    test "stores a pronunciation hint in the transcription brackets" do
      user = insert(:user)

      assert {:ok, updated} =
               Accounts.update_user(user, %{"name_pronunciation" => "SHTEH-fahn VIN-ter-my-er"})

      assert updated.name_pronunciation == "[SHTEH-fahn VIN-ter-my-er]"
      assert User.name_pronunciation(updated) == "[SHTEH-fahn VIN-ter-my-er]"
    end

    # The brackets are what tell a reader the line is a transcription, so they
    # are added rather than demanded — whichever one is missing, and never a
    # second copy of one the member already typed.
    test "adds only the bracket that is missing" do
      user = insert(:user)

      for {typed, stored} <- [
            {"[ˈʃtɛfan]", "[ˈʃtɛfan]"},
            {"[ˈʃtɛfan", "[ˈʃtɛfan]"},
            {"ˈʃtɛfan]", "[ˈʃtɛfan]"},
            {"ˈʃtɛfan", "[ˈʃtɛfan]"},
            # The phonemic /…/ spelling is not a delimiter we recognise, so it
            # is kept verbatim inside the brackets rather than rewritten.
            {"/ˈʃtɛfan/", "[/ˈʃtɛfan/]"}
          ] do
        assert {:ok, updated} = Accounts.update_user(user, %{"name_pronunciation" => typed})
        assert updated.name_pronunciation == stored
      end
    end

    test "empty brackets pronounce nothing and are refused" do
      user = insert(:user)

      for value <- ["[]", "["] do
        assert {:error, changeset} =
                 Accounts.update_user(user, %{"name_pronunciation" => value})

        assert "must spell out how the name sounds" in errors_on(changeset).name_pronunciation
      end
    end

    test "an empty field stays empty and reads as absent" do
      user = insert(:user)

      assert {:ok, updated} = Accounts.update_user(user, %{"name_pronunciation" => "   "})
      assert is_nil(updated.name_pronunciation)
      assert is_nil(User.name_pronunciation(updated))
    end

    test "clearing a stored pronunciation removes it" do
      user = insert(:user, name_pronunciation: "SHTEH-fahn")

      assert {:ok, updated} = Accounts.update_user(user, %{"name_pronunciation" => ""})
      assert is_nil(updated.name_pronunciation)
    end

    # It is one spoken line, so a pasted paragraph collapses instead of
    # breaking the profile line it renders into.
    test "folds whitespace into one line" do
      user = insert(:user)

      assert {:ok, updated} =
               Accounts.update_user(user, %{
                 "name_pronunciation" => "  SHTEH-fahn \n\n  VIN-ter-my-er  "
               })

      assert updated.name_pronunciation == "[SHTEH-fahn VIN-ter-my-er]"
    end

    test "refuses a value that pronounces nothing" do
      user = insert(:user)

      for value <- ["---", "???", "123", "https://www.example-shop.com/", "kontakt@example.com"] do
        assert {:error, changeset} =
                 Accounts.update_user(user, %{"name_pronunciation" => value})

        assert "must spell out how the name sounds" in errors_on(changeset).name_pronunciation
      end
    end

    test "accepts a hint that names a sound-alike with a dot in it" do
      user = insert(:user)
      hint = "like the 'stefan' in stefan.fm"

      assert {:ok, updated} = Accounts.update_user(user, %{"name_pronunciation" => hint})
      assert updated.name_pronunciation == "[#{hint}]"
    end

    # The cap is the column's, so it is checked on the value that is stored —
    # brackets included, which is why the form stops typing at 255 too.
    test "refuses more than 255 characters" do
      user = insert(:user)

      assert {:error, changeset} =
               Accounts.update_user(user, %{"name_pronunciation" => String.duplicate("a", 256)})

      assert "should be at most 255 character(s)" in errors_on(changeset).name_pronunciation

      assert {:ok, updated} =
               Accounts.update_user(user, %{"name_pronunciation" => String.duplicate("a", 253)})

      assert String.length(updated.name_pronunciation) == 255
    end

    # The verified badge vouches for the written name, not for how it sounds,
    # so fixing the hint must not cost the badge (unlike a name edit).
    test "keeps a verified badge" do
      user = insert(:user, identity_verified?: true)

      assert {:ok, updated} = Accounts.update_user(user, %{"name_pronunciation" => "SHTEH-fahn"})
      assert updated.identity_verified?
    end
  end

  describe "login_pins uniqueness" do
    test "rejects a second login pin for the same user and type" do
      user = insert(:user)

      assert {:ok, _} =
               %LoginPin{user_id: user.id}
               |> LoginPin.changeset(%{type: "login"})
               |> Repo.insert()

      assert {:error, changeset} =
               %LoginPin{user_id: user.id}
               |> LoginPin.changeset(%{type: "login"})
               |> Repo.insert()

      assert errors_on(changeset)[:user_id] == ["already has a login pin of this type"]
    end

    test "allows different login pin types for the same user" do
      user = insert(:user)

      assert {:ok, _} =
               %LoginPin{user_id: user.id}
               |> LoginPin.changeset(%{type: "login"})
               |> Repo.insert()

      assert {:ok, _} =
               %LoginPin{user_id: user.id}
               |> LoginPin.changeset(%{type: "email"})
               |> Repo.insert()
    end
  end

  describe "gen_pin_for/3" do
    test "returns a fresh 6-digit PIN and never stores it in plaintext" do
      user = insert(:user)

      pin = Accounts.gen_pin_for(user, "login")

      assert pin =~ ~r/\A\d{6}\z/

      login_pin = Repo.one(from(m in LoginPin, where: m.user_id == ^user.id))
      # The stored hash is a 64-hex-char HMAC, a per-PIN salt is present, and
      # neither equals the plaintext PIN.
      assert login_pin.pin_hash =~ ~r/\A[0-9a-f]{64}\z/
      assert login_pin.pin_hash != pin
      assert byte_size(login_pin.pin_salt) == 16
    end

    test "upserts a single row per (user, type)" do
      user = insert(:user)

      Accounts.gen_pin_for(user, "login")
      Accounts.gen_pin_for(user, "login")

      assert Repo.one(from(m in LoginPin, where: m.user_id == ^user.id, select: count(m.id))) == 1
    end

    test "concurrent first mints for a (user, type) pair never raise" do
      user = insert(:user)

      pins =
        Task.await_many(
          for _ <- 1..4 do
            Task.async(fn -> Accounts.gen_pin_for(user, "email", "new@example.com") end)
          end
        )

      assert Enum.all?(pins, &(byte_size(&1) == 6))

      assert Repo.aggregate(
               from(m in LoginPin, where: m.user_id == ^user.id and m.type == "email"),
               :count
             ) == 1
    end

    test "carries a payload for the email-change flow" do
      user = insert(:user)
      Accounts.gen_pin_for(user, "email", "new@example.com")

      assert Repo.one(from(m in LoginPin, where: m.user_id == ^user.id, select: m.payload)) ==
               "new@example.com"
    end
  end

  describe "check_pin/3" do
    test "accepts the correct PIN once and consumes it" do
      user = insert(:user)
      pin = Accounts.gen_pin_for(user, "delete")

      assert {:ok, %User{id: id}} = Accounts.check_pin(user, pin, "delete")
      assert id == user.id

      # A consumed PIN cannot be replayed, and it is reported as "already used"
      # rather than "expired": a double-submit of the classic PIN form right
      # after a successful login must not tell the member their fresh PIN timed
      # out (issue #839).
      assert {:already_used, _} = Accounts.check_pin(user, pin, "delete")
    end

    test "a re-submitted consumed login PIN reads as already used, not expired (issue #839)" do
      user = insert(:user)
      insert(:email, user: user, value: "dup@example.com")
      pin = Accounts.gen_pin_for(user, "login")

      # First submit logs in and consumes the PIN; the classic (non-LiveView)
      # PIN form can be posted twice (double-tap, back navigation, a retried
      # request), and that duplicate must not surface as "PIN expired".
      assert {:ok, %User{}} = Accounts.check_pin("dup@example.com", pin, "login")
      assert {:already_used, _} = Accounts.check_pin("dup@example.com", pin, "login")
    end

    test "re-minting a PIN clears the consumed marker" do
      user = insert(:user)
      pin = Accounts.gen_pin_for(user, "delete")
      assert {:ok, %User{}} = Accounts.check_pin(user, pin, "delete")
      assert {:already_used, _} = Accounts.check_pin(user, pin, "delete")

      # A freshly requested PIN starts a clean life — never seen as already used.
      pin = Accounts.gen_pin_for(user, "delete")
      assert {:ok, %User{}} = Accounts.check_pin(user, pin, "delete")
    end

    test "returns the carried value for the email-change flow" do
      user = insert(:user)
      pin = Accounts.gen_pin_for(user, "email", "new@example.com")

      assert {:ok, "new@example.com", %User{id: id}} = Accounts.check_pin(user, pin, "email")
      assert id == user.id
    end

    test "rejects a wrong PIN and locks out after three attempts" do
      user = insert(:user)
      _pin = Accounts.gen_pin_for(user, "delete")

      assert {:error, _} = Accounts.check_pin(user, "000000", "delete")
      assert {:error, _} = Accounts.check_pin(user, "000000", "delete")
      assert :lockout = Accounts.check_pin(user, "000000", "delete")
    end

    test "verifies a login PIN by email" do
      user = insert(:user)
      insert(:email, user: user, value: "login@example.com")
      pin = Accounts.gen_pin_for(user, "login")

      assert {:ok, %User{id: id}} = Accounts.check_pin("login@example.com", pin, "login")
      assert id == user.id
    end

    test "errors when no PIN exists for the identity" do
      user = insert(:user)
      assert {:error, _} = Accounts.check_pin(user, "123456", "delete")
    end

    # Guards the float/second day-arithmetic rewrite of `pin_expired?/1`: a PIN is
    # accepted just inside the 1800s window and rejected as expired just past it.
    test "honours the PIN expiry window (still valid before, expired after)" do
      user = insert(:user)
      pin = Accounts.gen_pin_for(user, "delete")

      backdate_pin(user, "delete", 1799)
      assert {:ok, %User{}} = Accounts.check_pin(user, pin, "delete")

      pin = Accounts.gen_pin_for(user, "delete")
      backdate_pin(user, "delete", 1801)
      assert {:expired, _} = Accounts.check_pin(user, pin, "delete")
    end
  end

  describe "first_email_value/1" do
    test "returns the lowest-position address deterministically, whatever the insert order" do
      user = insert(:user)
      insert(:email, user: user, value: "third@example.com", position: 3)
      insert(:email, user: user, value: "first@example.com", position: 1)
      insert(:email, user: user, value: "second@example.com", position: 2)

      assert Accounts.first_email_value(user) == "first@example.com"
    end
  end

  describe "count_users/0" do
    test "counts confirmed members (activated, or legacy nil-activated)" do
      base = Accounts.count_users()
      insert(:activated_user)
      insert(:activated_user)
      insert(:user, email_confirmed?: nil)
      assert Accounts.count_users() == base + 3
    end

    test "excludes never-confirmed registrations (email_confirmed? == false, issue #781)" do
      base = Accounts.count_users()
      insert(:user)
      insert(:user)
      assert Accounts.count_users() == base
    end
  end

  describe "delete_unconfirmed_registrations/1" do
    test "deletes a registration that never confirmed its PIN once it is over an hour old" do
      user = pending_registration(age_minutes: 61)

      assert Accounts.delete_unconfirmed_registrations() == 1
      refute Repo.get(User, user.id)
    end

    test "spares a registration younger than the threshold" do
      user = pending_registration(age_minutes: 30)

      assert Accounts.delete_unconfirmed_registrations() == 0
      assert Repo.get(User, user.id)
    end

    test "spares an account that has been activated, however old" do
      user = pending_registration(age_minutes: 1_000, email_confirmed?: true)

      assert Accounts.delete_unconfirmed_registrations() == 0
      assert Repo.get(User, user.id)
    end

    # The critical safety case: an established (e.g. legacy) member is
    # `email_confirmed?: false` and mints a fresh "login" PIN when they try to sign in.
    # Because that PIN was created long after the account, it must NOT be reaped
    # as an abandoned registration.
    test "never deletes a legacy member who merely failed to log in" do
      user = insert(:user, email_confirmed?: false)
      set_inserted_at(from(u in User, where: u.id == ^user.id), 60 * 24 * 365 * 5)
      # They attempt a login now: a brand-new PIN, years after the account.
      Accounts.gen_pin_for(user, "login")

      assert Accounts.delete_unconfirmed_registrations() == 0
      assert Repo.get(User, user.id)
    end

    test "never deletes an unconfirmed account that has no login PIN at all" do
      user = insert(:user, email_confirmed?: false)
      set_inserted_at(from(u in User, where: u.id == ^user.id), 1_000)

      assert Accounts.delete_unconfirmed_registrations() == 0
      assert Repo.get(User, user.id)
    end

    # The expired-PIN screen promises "we delete it automatically in about N
    # minutes", with N from `unconfirmed_registration_grace_minutes/0`. That is
    # a promise about *this* function, so pin the two to each other rather than
    # letting the sentence and the sweep drift apart: a sign-up a minute short
    # of the promised total is still here, one a minute past it is gone.
    test "the grace the PIN screen promises is the grace this sweep leaves" do
      total = Accounts.pin_validity_minutes() + Accounts.unconfirmed_registration_grace_minutes()

      still_promised = pending_registration(age_minutes: total - 1)
      assert Accounts.delete_unconfirmed_registrations() == 0
      assert Repo.get(User, still_promised.id)

      past_the_promise = pending_registration(age_minutes: total + 1)
      assert Accounts.delete_unconfirmed_registrations() == 1
      refute Repo.get(User, past_the_promise.id)
      assert Repo.get(User, still_promised.id)
    end
  end

  describe "delete_unconfirmed_legacy_registrations/1" do
    # An abandoned registration from the backlog: unconfirmed and old, with no
    # login PIN left (they expire and are cleared), which is exactly why the
    # periodic sweep above can never reach it.
    defp stale_registration(days_old \\ 30) do
      user = insert(:user, email_confirmed?: false)
      set_inserted_at(from(u in User, where: u.id == ^user.id), days_old * 24 * 60)
      Repo.get!(User, user.id)
    end

    test "deletes an old unconfirmed registration and everything hanging off it" do
      user = stale_registration()
      email = insert(:email, user: user)
      tag = insert(:tag, name: unique_tag_name("Karteileiche"))
      user_tag = insert(:user_tag, user: user, tag: tag)

      assert {1, _} = Accounts.delete_unconfirmed_legacy_registrations()

      refute Repo.get(User, user.id)
      refute Repo.get(Vutuv.Accounts.Email, email.id)
      refute Repo.get(Vutuv.Tags.UserTag, user_tag.id)
      # The tag row itself is a separate cleanup's business, not this one's.
      assert Repo.get(Vutuv.Tags.Tag, tag.id)
    end

    # The two account states that make up the protected member count.
    test "never touches a confirmed account, however old" do
      user = insert(:activated_user)
      set_inserted_at(from(u in User, where: u.id == ^user.id), 365 * 24 * 60)

      assert {0, _} = Accounts.delete_unconfirmed_legacy_registrations()
      assert Repo.get(User, user.id)
    end

    # A member from before the flag existed: `email_confirmed?` is NULL, which
    # the schema's `default: false` makes unreachable through a changeset, so
    # the column is set directly — exactly the state the real legacy rows are in.
    defp legacy_member do
      user = insert(:user)
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [email_confirmed?: nil])
      Repo.get!(User, user.id)
    end

    test "never touches a legacy member whose email_confirmed? is NULL" do
      # The critical case: these accounts predate the flag and count as members.
      # `email_confirmed? == false` must not match NULL under SQL three-valued
      # logic, and this is what proves it.
      user = legacy_member()
      assert is_nil(user.email_confirmed?)
      set_inserted_at(from(u in User, where: u.id == ^user.id), 365 * 24 * 60)

      assert {0, _} = Accounts.delete_unconfirmed_legacy_registrations()
      assert Repo.get(User, user.id)
    end

    test "spares a registration inside the grace period" do
      user = stale_registration(3)

      assert {0, _} = Accounts.delete_unconfirmed_legacy_registrations(7)
      assert Repo.get(User, user.id)
    end

    test "keeps the protected member count exactly intact" do
      confirmed = insert(:activated_user)
      legacy = legacy_member()
      stale_registration()
      before = Accounts.count_users()

      assert {1, _} = Accounts.delete_unconfirmed_legacy_registrations()

      assert Accounts.count_users() == before
      assert Repo.get(User, confirmed.id)
      assert Repo.get(User, legacy.id)
    end

    # Fail closed: the sweep's whole premise is that these accounts never got
    # started. Any evidence to the contrary stops it rather than deleting on a
    # wrong assumption.
    test "refuses to run when a candidate is an admin" do
      user = stale_registration()
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [admin?: true])

      assert_raise RuntimeError, ~r/admin/i, fn ->
        Accounts.delete_unconfirmed_legacy_registrations()
      end

      assert Repo.get(User, user.id)
    end

    test "refuses to run when a candidate has written a post" do
      user = stale_registration()
      insert(:post, user: user)

      assert_raise RuntimeError, ~r/posts/, fn ->
        Accounts.delete_unconfirmed_legacy_registrations()
      end

      assert Repo.get(User, user.id)
    end

    # The guard reads the live foreign keys rather than a list of activity
    # tables, so a table nobody thought about still stops it. `post_bookmarks`
    # stands in for exactly that: it is named nowhere in the cleanup.
    test "refuses on a table the cleanup never names, found through the catalog" do
      user = stale_registration()

      Repo.insert!(%Vutuv.Posts.PostBookmark{user_id: user.id, post_id: insert(:post).id})

      assert_raise RuntimeError, ~r/post_bookmarks/, fn ->
        Accounts.delete_unconfirmed_legacy_registrations()
      end

      assert Repo.get(User, user.id)
    end

    # The rows a bare sign-up writes must NOT trip the guard, or the cleanup
    # could never run at all.
    test "an email, a handle and tags do not count as activity" do
      user = stale_registration()
      insert(:email, user: user)
      insert(:user_tag, user: user, tag: insert(:tag, name: unique_tag_name("Anmeldung")))
      # Somebody else following the account is their action, not its use.
      insert(:follow, follower: insert(:activated_user), followee: user)

      assert {1, _} = Accounts.delete_unconfirmed_legacy_registrations()
      refute Repo.get(User, user.id)
    end

    test "refuses to run when a candidate has ever held a session" do
      user = stale_registration()

      Repo.insert!(%Vutuv.Sessions.UserSession{
        user_id: user.id,
        token_hash: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        last_seen_at: DateTime.utc_now(:second)
      })

      assert_raise RuntimeError, ~r/user_sessions/, fn ->
        Accounts.delete_unconfirmed_legacy_registrations()
      end

      assert Repo.get(User, user.id)
    end

    test "is idempotent" do
      stale_registration()

      assert {1, _} = Accounts.delete_unconfirmed_legacy_registrations()
      assert {0, _} = Accounts.delete_unconfirmed_legacy_registrations()
    end
  end

  describe "moderation removal filter + restore" do
    test "the spam flag lists only accounts marked as spam" do
      spammer = insert(:activated_user, deactivated_at: naive_now(), moderation_reason: "spam")
      _other_deactivated = insert(:activated_user, deactivated_at: naive_now())
      _plain = insert(:activated_user)

      filters = Accounts.admin_user_filters(%{"flag" => "spam", "reg" => "all"})
      ids = Accounts.list_admin_users(filters) |> Enum.map(& &1.id)

      assert spammer.id in ids
      assert length(ids) == 1
    end

    test "admin_user_filters accepts the spam flag" do
      assert %{flag: "spam"} = Accounts.admin_user_filters(%{"flag" => "spam"})
      assert %{flag: "all"} = Accounts.admin_user_filters(%{"flag" => "bogus"})
    end

    test "admin_restore_user clears the removal fields" do
      user =
        insert(:activated_user,
          deactivated_at: naive_now(),
          frozen_at: naive_now(),
          moderation_reason: "spam"
        )

      assert {:ok, restored} = Accounts.admin_restore_user(user)
      refute restored.deactivated_at
      refute restored.frozen_at
      refute restored.moderation_reason
    end

    test "admin_restore_user leaves a strike suspension in place" do
      until = NaiveDateTime.add(naive_now(), 86_400)
      user = insert(:activated_user, deactivated_at: naive_now(), suspended_until: until)

      assert {:ok, restored} = Accounts.admin_restore_user(user)
      refute restored.deactivated_at
      assert restored.suspended_until
    end
  end

  defp naive_now, do: NaiveDateTime.utc_now(:second)
end
