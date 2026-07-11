defmodule Vutuv.Accounts.LegacyUsernameNormalizationTest do
  @moduledoc """
  `Accounts.normalize_legacy_usernames/0` - the one-off backfill that renames
  every charset-invalid legacy handle (the dotted / over-length imports) to a
  valid handle regenerated from the member's name, preserving the old handle in
  `users.legacy_username` so it is never lost and the profile URL keeps
  redirecting.
  """
  use Vutuv.DataCase

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Handles

  defp valid_handle?(handle) do
    Regex.match?(~r/\A[a-z0-9_]+\z/, handle) and String.length(handle) <= Handles.max_length()
  end

  test "regenerates a valid handle from the member's name and preserves the old one" do
    user = insert(:user, username: "oliver.gassner", first_name: "Oliver", last_name: "Gassner")

    assert Accounts.normalize_legacy_usernames() == 1

    reloaded = Repo.get!(User, user.id)
    assert reloaded.username == "oliver_gassner"
    assert reloaded.legacy_username == "oliver.gassner"
  end

  test "leaves an already-valid handle untouched and stores no legacy handle" do
    user = insert(:user, username: "valid_handle", first_name: "Val", last_name: "Id")

    assert Accounts.normalize_legacy_usernames() == 0

    reloaded = Repo.get!(User, user.id)
    assert reloaded.username == "valid_handle"
    assert reloaded.legacy_username == nil
  end

  test "suffixes a collision when two members regenerate to the same handle" do
    a = insert(:user, username: "a.b.one", first_name: "Same", last_name: "Name")
    b = insert(:user, username: "a.b.two", first_name: "Same", last_name: "Name")

    assert Accounts.normalize_legacy_usernames() == 2

    handle_a = Repo.get!(User, a.id).username
    handle_b = Repo.get!(User, b.id).username

    assert handle_a != handle_b
    assert valid_handle?(handle_a) and valid_handle?(handle_b)
  end

  test "mints a unique handle for every member even when many share one name" do
    for i <- 1..8 do
      insert(:user, username: "jane.roe.#{i}", first_name: "Jane", last_name: "Roe")
    end

    assert Accounts.normalize_legacy_usernames() == 8

    handles =
      User
      |> Repo.all()
      |> Enum.reject(&is_nil(&1.legacy_username))
      |> Enum.map(& &1.username)

    assert length(handles) == 8
    assert length(Enum.uniq(handles)) == 8, "expected 8 distinct handles, got #{inspect(handles)}"
    assert Enum.all?(handles, &valid_handle?/1)
  end

  test "does not collide a regenerated handle with an existing valid handle" do
    # An already-valid member holds exactly the handle the legacy member's name
    # would normalize to; the legacy one must be pushed onto a unique variant.
    insert(:user, username: "jane_roe", first_name: "Jane", last_name: "Roe")
    legacy = insert(:user, username: "jane.roe", first_name: "Jane", last_name: "Roe")

    assert Accounts.normalize_legacy_usernames() == 1

    assert Repo.get!(User, legacy.id).username != "jane_roe"
    assert valid_handle?(Repo.get!(User, legacy.id).username)
  end

  test "is idempotent - a second run renames nothing and changes no handle" do
    user = insert(:user, username: "x.y.z", first_name: "Ex", last_name: "Why")

    assert Accounts.normalize_legacy_usernames() == 1
    after_first = Repo.get!(User, user.id).username

    assert Accounts.normalize_legacy_usernames() == 0
    assert Repo.get!(User, user.id).username == after_first
  end
end
