defmodule Vutuv.HandlesTest do
  @moduledoc """
  The shared `@handle` namespace (issue #941): members and organizations live in one
  root namespace whose global uniqueness is guaranteed by the `handles` registry
  table. These tests pin the two things that must never break: the registry
  stays in lock-step with the owner columns (`users.username` /
  `organizations.username`), and no member and organization can hold the same handle — in
  either direction, at the database.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Accounts.Handle
  alias Vutuv.Handles
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Repo

  defp build_conn do
    %Plug.Conn{
      assigns: %{locale: "en"},
      private: %{plug_session: %{}, plug_session_fetch: :done}
    }
    |> Plug.Test.init_test_session(%{})
  end

  # A member whose handle is registered exactly as production does it (via the
  # register_user chokepoint), so the `handles` row exists.
  defp member_with_handle(username) do
    user = insert(:activated_user, username: username)
    {:ok, _handle} = Handles.put_user_handle(user)
    user
  end

  defp verified_organization(user, host) do
    attrs = %{
      "name" => "Acme #{host}",
      "kind" => "company",
      "website_url" => "https://#{host}",
      "city" => "Köln",
      "country" => "DE"
    }

    {:ok, %{organization: organization}} =
      Organizations.create_pending_organization(user, attrs, "dns")

    # A root handle can only be claimed by a verified (active) page.
    organization
    |> Organization.status_changeset("active")
    |> Repo.update!()
  end

  describe "registry sync (the chokepoints keep handles in lock-step)" do
    test "register_user writes a matching handle row" do
      {:ok, user} =
        Accounts.register_user(build_conn(), %{
          "emails" => %{"0" => %{"value" => "reg@example.com"}},
          "first_name" => "Reg",
          "last_name" => "Ister",
          "tag_list" => "Elixir Cooking Origami"
        })

      handle = Repo.get_by(Handle, user_id: user.id)
      assert handle
      assert handle.value == user.username
    end

    test "update_username moves the member's handle row to the new value" do
      user = member_with_handle("old_handle")

      {:ok, renamed} = Accounts.update_username(user, %{"username" => "new_handle"})

      handle = Repo.get_by(Handle, user_id: user.id)
      assert handle.value == "new_handle"
      assert renamed.username == "new_handle"
      # Exactly one row per owner — the rename moved it, not added one.
      assert Repo.aggregate(from(h in Handle, where: h.user_id == ^user.id), :count) == 1
    end

    test "claim_handle writes the organization's handle row" do
      owner = insert(:activated_user)
      organization = verified_organization(owner, "acme.example")

      assert {:ok, updated} = Organizations.claim_handle(organization, %{"username" => "acme"})
      assert updated.username == "acme"

      handle = Repo.get_by(Handle, organization_id: organization.id)
      assert handle.value == "acme"
      assert is_nil(handle.user_id)
    end

    test "claim_handle changes an existing organization handle in place" do
      owner = insert(:activated_user)
      organization = verified_organization(owner, "acme.example")

      {:ok, organization} = Organizations.claim_handle(organization, %{"username" => "acme"})
      {:ok, organization} = Organizations.claim_handle(organization, %{"username" => "acmecorp"})

      assert organization.username == "acmecorp"

      assert Repo.aggregate(
               from(h in Handle, where: h.organization_id == ^organization.id),
               :count
             ) == 1

      assert Repo.get_by(Handle, organization_id: organization.id).value == "acmecorp"
    end
  end

  describe "cross-table uniqueness (the whole point)" do
    test "an organization cannot claim a member's handle" do
      _member = member_with_handle("lufthansa")
      owner = insert(:activated_user)
      organization = verified_organization(owner, "acme.example")

      assert {:error, changeset} =
               Organizations.claim_handle(organization, %{"username" => "lufthansa"})

      assert "has already been taken" in errors_on(changeset).username
      # The organization row is unchanged (the transaction rolled back).
      assert is_nil(Repo.reload(organization).username)
    end

    test "a member cannot rename onto an organization's handle" do
      owner = insert(:activated_user)
      organization = verified_organization(owner, "acme.example")
      {:ok, _organization} = Organizations.claim_handle(organization, %{"username" => "acme"})

      member = member_with_handle("someone")

      assert {:error, changeset} = Accounts.update_username(member, %{"username" => "acme"})
      assert "has already been taken" in errors_on(changeset).username
      # The rename rolled back: the member keeps the old handle in both places.
      assert Repo.reload(member).username == "someone"
      assert Repo.get_by(Handle, user_id: member.id).value == "someone"
    end

    test "two organizations cannot hold the same handle" do
      owner = insert(:activated_user)
      a = verified_organization(owner, "a.example")
      b = verified_organization(owner, "b.example")

      {:ok, _a} = Organizations.claim_handle(a, %{"username" => "shared"})

      assert {:error, changeset} = Organizations.claim_handle(b, %{"username" => "shared"})
      assert "has already been taken" in errors_on(changeset).username
    end
  end

  describe "handle grammar + reserved words (both account types)" do
    test "organization handle rejects invalid grammar" do
      owner = insert(:activated_user)
      organization = verified_organization(owner, "acme.example")

      assert {:error, changeset} =
               Organizations.claim_handle(organization, %{"username" => "no spaces"})

      refute changeset.valid?
      assert changeset.errors[:username]
    end

    test "organization handle rejects a reserved route word" do
      owner = insert(:activated_user)
      organization = verified_organization(owner, "acme.example")

      assert {:error, changeset} =
               Organizations.claim_handle(organization, %{"username" => "admin"})

      assert "is reserved" in errors_on(changeset).username
    end

    test "organization handle is lowercased" do
      owner = insert(:activated_user)
      organization = verified_organization(owner, "acme.example")

      {:ok, organization} = Organizations.claim_handle(organization, %{"username" => "AcmeCorp"})
      assert organization.username == "acmecorp"
    end
  end

  describe "available?/1" do
    test "false for a taken member handle, a reserved word, and non-binaries" do
      _member = member_with_handle("takenone")

      refute Handles.available?("takenone")
      refute Handles.available?("admin")
      refute Handles.available?(nil)
    end

    test "true for a free handle" do
      assert Handles.available?("totally_free")
    end
  end
end
