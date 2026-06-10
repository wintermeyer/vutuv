defmodule Vutuv.Accounts.SlugTest do
  @moduledoc """
  Finding [21]: `can_create_slug?/2` rate-limits how many slugs a user may mint
  in a time window, using FLOAT day arithmetic (seconds / 86_400) so the 30/90
  day thresholds aren't truncated at sub-day boundaries. These tests pin that
  threshold behaviour after the gregorian-seconds idiom was replaced with
  `NaiveDateTime.diff(_, _, :second) / 86_400`.
  """
  use Vutuv.DataCase

  alias Vutuv.Accounts.ReservedSlugs
  alias Vutuv.Accounts.Slug

  # Mirrors the controller: a new slug is built off the user (so `user_id` is set)
  # before `changeset/2` runs `can_create_slug?/2`.
  defp new_slug_changeset(user, value \\ "newslug") do
    %Slug{user_id: user.id}
    |> Slug.changeset(%{value: value})
  end

  defp days_ago(days) do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-round(days * 86_400), :second)
    |> NaiveDateTime.truncate(:second)
  end

  test "the very first slug is always allowed (no existing slugs)" do
    user = insert(:user, inserted_at: days_ago(365))
    assert new_slug_changeset(user).valid?
  end

  test "under three slugs is allowed only while the account is younger than 30 days" do
    young = insert(:user, inserted_at: days_ago(10))
    insert(:slug, user: young)
    assert new_slug_changeset(young).valid?

    old = insert(:user, inserted_at: days_ago(40))
    insert(:slug, user: old)
    refute new_slug_changeset(old).valid?

    assert "Reached max new slugs in time period." in errors_on(new_slug_changeset(old)).value
  end

  describe "reserved slugs" do
    test "route and asset path words cannot be claimed as slugs" do
      # Profiles live at the URL root, so a slug equal to a route prefix
      # would shadow that user's profile forever.
      for value <- ["tags", "login", "messages", "assets", "robots.txt", "users"] do
        changeset = Slug.changeset(%Slug{}, %{value: value})
        refute changeset.valid?, "expected #{value} to be rejected"
        assert "is reserved" in errors_on(changeset).value
      end
    end

    test "generated slugs skip reserved words by appending a suffix" do
      reserved = ReservedSlugs.list()
      user = %Vutuv.Accounts.User{first_name: "Login", last_name: nil}

      slug = Vutuv.SlugHelpers.gen_slug_unique(user, Slug, :value, reserved)

      assert slug =~ ~r/^login\.[0-9a-f]{8}$/
      refute slug in reserved
    end

    test "registration around a reserved name still succeeds" do
      # register_user/2 generates the slug from the name; "Tags" slugifies to
      # the reserved word "tags" and must come out suffixed, not rejected.
      conn = %Plug.Conn{assigns: %{locale: "en"}}

      {:ok, user} =
        Vutuv.Accounts.register_user(conn, %{
          "first_name" => "Tags",
          "emails" => %{"0" => %{"value" => "tags@example.com"}}
        })

      assert user.active_slug =~ ~r/^tags\.[0-9a-f]{8}$/
    end
  end

  test "with three or more slugs a new one needs the last slug to be over 90 days old" do
    user = insert(:user, inserted_at: days_ago(200))

    # Three existing slugs; the most recent one drives `last_slug_inserted_days`.
    insert(:slug, user: user, inserted_at: days_ago(120))
    insert(:slug, user: user, inserted_at: days_ago(110))
    recent = insert(:slug, user: user, inserted_at: days_ago(10))

    refute new_slug_changeset(user).valid?

    # Push the most recent slug past the 90-day mark.
    recent
    |> Ecto.Changeset.change(inserted_at: days_ago(95))
    |> Repo.update!()

    assert new_slug_changeset(user).valid?
  end
end
