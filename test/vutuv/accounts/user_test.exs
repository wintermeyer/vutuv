defmodule Vutuv.Accounts.UserTest do
  use Vutuv.DataCase

  alias Vutuv.Accounts.User

  @valid_attrs %{"first_name" => "first_name"}
  @invalid_email_attrs %{
    "first_name" => "first_name",
    "emails" => %{"0" => %{"value" => "invalid email"}}
  }

  test "changeset with valid attributes" do
    changeset = User.changeset(%User{}, @valid_attrs)
    assert changeset.valid?
  end

  test "changeset ignores email params (emails change only via the PIN flow)" do
    changeset = User.changeset(%User{}, @invalid_email_attrs)
    assert changeset.valid?
    refute Ecto.Changeset.get_change(changeset, :emails)
  end

  test "registration_changeset casts and validates the initial email" do
    changeset = User.registration_changeset(%User{}, @invalid_email_attrs)
    refute changeset.valid?
  end

  test "rejects a locale longer than its varchar(255) column" do
    changeset =
      User.changeset(%User{}, %{
        "first_name" => "first_name",
        "locale" => String.duplicate("a", 300)
      })

    refute changeset.valid?
    assert %{locale: [_]} = errors_on(changeset)
  end

  describe "post-display preferences" do
    test "post_prefs/1 returns the logged-out defaults for a nil viewer" do
      assert User.post_prefs(nil) == %{
               lines_desktop: 6,
               lines_mobile: 8,
               hyphenate_desktop: false,
               hyphenate_mobile: true
             }
    end

    test "post_prefs/1 resolves a fresh (all-nil) account to the shipped defaults" do
      assert User.post_prefs(%User{}) == User.post_prefs_defaults()
    end

    test "post_prefs/1 keeps an explicit 0 as no-truncation while nil inherits" do
      prefs = User.post_prefs(%User{post_lines_desktop: 0, post_lines_mobile: nil})
      assert prefs.lines_desktop == 0
      assert prefs.lines_mobile == 8
    end

    test "post_prefs/1 reads the stored per-breakpoint values" do
      user = %User{
        post_lines_desktop: 4,
        post_lines_mobile: 0,
        post_hyphenate_desktop: true,
        post_hyphenate_mobile: false
      }

      assert User.post_prefs(user) == %{
               lines_desktop: 4,
               lines_mobile: 0,
               hyphenate_desktop: true,
               hyphenate_mobile: false
             }
    end

    test "changeset accepts a valid line count and the hyphenation switches" do
      changeset =
        User.changeset(%User{}, %{
          "first_name" => "first_name",
          "post_lines_desktop" => "10",
          "post_lines_mobile" => "0",
          "post_hyphenate_desktop" => "true",
          "post_hyphenate_mobile" => "false"
        })

      assert changeset.valid?
    end

    test "changeset rejects a negative line count" do
      changeset =
        User.changeset(%User{}, %{"first_name" => "first_name", "post_lines_desktop" => "-1"})

      refute changeset.valid?
      assert %{post_lines_desktop: [_]} = errors_on(changeset)
    end

    test "changeset rejects a line count above the cap" do
      changeset =
        User.changeset(%User{}, %{
          "first_name" => "first_name",
          "post_lines_mobile" => Integer.to_string(User.post_lines_max() + 1)
        })

      refute changeset.valid?
      assert %{post_lines_mobile: [_]} = errors_on(changeset)
    end

    test "changeset accepts 0 as a valid line count (no truncation)" do
      changeset =
        User.changeset(%User{first_name: "first_name"}, %{"post_lines_desktop" => "0"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :post_lines_desktop) == 0
    end
  end

  describe "birthdate" do
    defp birthdate_changeset(birthdate) do
      User.changeset(%User{}, %{"first_name" => "first_name", "birthdate" => birthdate})
    end

    test "accepts a normal past date" do
      assert birthdate_changeset(~D[1990-05-15]).valid?
    end

    test "accepts no birthdate at all" do
      assert User.changeset(%User{}, %{"first_name" => "first_name"}).valid?
    end

    test "rejects a date in the future" do
      future = Date.add(Vutuv.BerlinTime.today(), 1)
      changeset = birthdate_changeset(future)

      refute changeset.valid?
      assert %{birthdate: [_]} = errors_on(changeset)
    end

    test "rejects an implausibly old date (more than 120 years ago)" do
      changeset = birthdate_changeset(~D[1800-01-01])

      refute changeset.valid?
      assert %{birthdate: [_]} = errors_on(changeset)
    end

    test "still nils out the 1900-01-01 \"unset\" sentinel without erroring" do
      changeset = birthdate_changeset(~D[1900-01-01])

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :birthdate) == nil
    end
  end

  describe "identity verification revocation" do
    # A member an admin has already verified (their physical ID was checked
    # against this name and birthday).
    defp verified_user do
      %User{
        identity_verified?: true,
        first_name: "Erika",
        last_name: "Mustermann",
        birthdate: ~D[1980-01-01]
      }
    end

    test "changing the first name revokes the verification" do
      changeset = User.changeset(verified_user(), %{"first_name" => "Imposter"})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "changing the last name revokes the verification" do
      changeset = User.changeset(verified_user(), %{"last_name" => "Other"})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "changing the middle name revokes the verification" do
      changeset = User.changeset(verified_user(), %{"middle_name" => "Zweitname"})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "changing the birthday revokes the verification" do
      changeset = User.changeset(verified_user(), %{"birthdate" => ~D[1990-12-31]})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "changing the nickname revokes the verification" do
      changeset = User.changeset(verified_user(), %{"nickname" => "Eri"})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "adding an honorific title revokes the verification" do
      changeset = User.changeset(verified_user(), %{"honorific_prefix" => "Dr."})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "changing the gender revokes the verification" do
      changeset = User.changeset(verified_user(), %{"gender" => "female"})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "editing a non-identity field (headline) keeps the verification" do
      changeset = User.changeset(verified_user(), %{"headline" => "Now hiring"})
      refute Ecto.Changeset.get_change(changeset, :identity_verified?)
    end

    test "resubmitting the same name and birthday keeps the verification" do
      changeset =
        User.changeset(verified_user(), %{
          "first_name" => "Erika",
          "last_name" => "Mustermann",
          "birthdate" => ~D[1980-01-01]
        })

      refute Ecto.Changeset.get_change(changeset, :identity_verified?)
    end

    test "an unverified member never gets a spurious verification change" do
      unverified = %User{identity_verified?: false, first_name: "Erika"}
      changeset = User.changeset(unverified, %{"first_name" => "Imposter"})
      refute Ecto.Changeset.get_change(changeset, :identity_verified?)
    end
  end

  describe "employment status (issue #870)" do
    defp employment_changeset(status) do
      User.changeset(%User{}, %{"first_name" => "first_name", "employment_status" => status})
    end

    test "accepts open and looking" do
      assert employment_changeset("open").valid?
      assert Ecto.Changeset.get_field(employment_changeset("open"), :employment_status) == "open"

      assert employment_changeset("looking").valid?
    end

    test "the blank \"not open to work\" choice folds back to nil" do
      changeset = employment_changeset("")

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :employment_status) == nil
    end

    test "accepts no employment status at all" do
      assert User.changeset(%User{}, %{"first_name" => "first_name"}).valid?
    end

    test "rejects an unknown value" do
      changeset = employment_changeset("freelancing")

      refute changeset.valid?
      assert %{employment_status: [_]} = errors_on(changeset)
    end

    test "clearing a previously set status back to \"not open\" saves nil" do
      user = %User{first_name: "first_name", employment_status: "looking"}
      changeset = User.changeset(user, %{"employment_status" => ""})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :employment_status) == nil
    end

    test "employment_status_label/1 translates the known values and nils the rest" do
      assert User.employment_status_label("open") == "Open to offers"
      assert User.employment_status_label("looking") == "Looking for a job"
      assert User.employment_status_label(nil) == nil
      assert User.employment_status_label("bogus") == nil
    end
  end

  describe "employment-status visibility (issue #928)" do
    test "defaults to members" do
      assert %User{}.employment_status_visibility == "members"
    end

    test "accepts the three visibility values" do
      for visibility <- ~w(everyone members hidden) do
        changeset =
          User.changeset(%User{}, %{
            "first_name" => "first_name",
            "employment_status_visibility" => visibility
          })

        assert changeset.valid?
      end
    end

    test "rejects an unknown visibility value" do
      changeset =
        User.changeset(%User{}, %{
          "first_name" => "first_name",
          "employment_status_visibility" => "boss_only"
        })

      refute changeset.valid?
      assert %{employment_status_visibility: [_]} = errors_on(changeset)
    end

    test "employment_status_visible?/2 gates on the status being set" do
      refute User.employment_status_visible?(%User{employment_status: nil}, %User{})

      refute User.employment_status_visible?(
               %User{employment_status: nil, employment_status_visibility: "everyone"},
               %User{}
             )
    end

    test "\"everyone\" shows to a logged-out viewer and a member alike" do
      user = %User{employment_status: "looking", employment_status_visibility: "everyone"}

      assert User.employment_status_visible?(user, nil)
      assert User.employment_status_visible?(user, %User{})
    end

    test "\"members\" shows only to a signed-in viewer" do
      user = %User{employment_status: "looking", employment_status_visibility: "members"}

      refute User.employment_status_visible?(user, nil)
      assert User.employment_status_visible?(user, %User{})
    end

    test "\"hidden\" shows to nobody, viewer or not" do
      user = %User{employment_status: "looking", employment_status_visibility: "hidden"}

      refute User.employment_status_visible?(user, nil)
      refute User.employment_status_visible?(user, %User{})
    end

    test "a nil/legacy visibility falls back to the members rule" do
      user = %User{employment_status: "open", employment_status_visibility: nil}

      refute User.employment_status_visible?(user, nil)
      assert User.employment_status_visible?(user, %User{})
    end

    test "employment_status_visibility_label/1 translates each choice and nils the rest" do
      assert User.employment_status_visibility_label("everyone") =~ "Everyone"
      assert User.employment_status_visibility_label("members") =~ "members"
      assert User.employment_status_visibility_label("hidden") =~ "No one"
      assert User.employment_status_visibility_label("bogus") == nil
    end
  end

  describe "tag list" do
    defp tag_list_changeset(tag_list) do
      User.changeset(%User{}, %{"first_name" => "first_name", "tag_list" => tag_list})
    end

    # The virtual `tag_list` is not validated on the changeset: it is split into
    # real tags after the row commits (Accounts.register_user/3), on both commas
    # and spaces, so any string is accepted here. A run of words is no longer an
    # error, it just becomes several tags. See tags_test.exs / page_controller_test.exs.
    test "accepts a comma-separated list" do
      assert tag_list_changeset("Elixir, Cooking, Go").valid?
    end

    test "accepts a run of space-separated words" do
      assert tag_list_changeset("JavaScript Go Hunde").valid?
    end

    test "accepts no tags at all" do
      assert User.changeset(%User{}, %{"first_name" => "first_name"}).valid?
    end
  end
end
