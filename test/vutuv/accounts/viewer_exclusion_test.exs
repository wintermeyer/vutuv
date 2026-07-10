defmodule Vutuv.Accounts.ViewerExclusionTest do
  @moduledoc """
  The per-member job-search viewer-exclusion list (issue #938): the schema
  validations, the Accounts CRUD, and the reusable visibility seam
  (`viewer_excluded?/2` + `job_search_visibility/2`) that subtracts
  excluded viewers as the LAST step of the #928 gate.
  """

  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Accounts.ViewerExclusion

  defp owner(attrs \\ []), do: insert(:activated_user, attrs)

  describe "domain_changeset/2 normalization + validation" do
    test "normalizes case, scheme, path and a user@ prefix down to the bare host" do
      me = owner()

      for input <- [
            "Example.COM",
            "https://example.com",
            "http://example.com/careers",
            "boss@example.com",
            "  example.com  "
          ] do
        cs = ViewerExclusion.domain_changeset(me, %{"domain" => input})
        assert cs.valid?, "expected #{inspect(input)} to normalize to a valid domain"
        assert Ecto.Changeset.get_change(cs, :domain) == "example.com"
      end
    end

    test "rejects a value that is not a bare hostname" do
      me = owner()

      for bad <- ["nodot", "spaces in it", "-leadinghyphen.com", ""] do
        refute ViewerExclusion.domain_changeset(me, %{"domain" => bad}).valid?
      end
    end

    test "rejects a domain longer than the column allows" do
      me = owner()
      long = String.duplicate("a", 250) <> ".com"
      cs = ViewerExclusion.domain_changeset(me, %{"domain" => long})
      refute cs.valid?
      assert %{domain: _} = errors_on(cs)
    end
  end

  describe "add_excluded_member/2" do
    test "excludes a member found by @handle (with or without the @)" do
      me = owner()
      boss = insert(:activated_user, username: "the-boss")

      assert {:ok, _} = Accounts.add_excluded_member(me, "@the-boss")
      assert [%ViewerExclusion{excluded_user_id: id}] = Accounts.list_viewer_exclusions(me)
      assert id == boss.id
    end

    test "resolves a mixed-case @handle (usernames are stored lowercase)" do
      me = owner()
      insert(:activated_user, username: "the-boss")
      assert {:ok, _} = Accounts.add_excluded_member(me, "@The-Boss")
      assert Accounts.viewer_exclusion_count(me) == 1
    end

    test "refuses an unknown handle, self, and a duplicate" do
      me = owner(username: "me")
      insert(:activated_user, username: "colleague")

      assert {:error, :not_found} = Accounts.add_excluded_member(me, "nobody-here")
      assert {:error, :self} = Accounts.add_excluded_member(me, "me")

      assert {:ok, _} = Accounts.add_excluded_member(me, "colleague")
      assert {:error, :duplicate} = Accounts.add_excluded_member(me, "colleague")
      assert Accounts.viewer_exclusion_count(me) == 1
    end

    test "refuses once the list is full" do
      me = owner()
      for _ <- 1..Accounts.viewer_exclusion_cap(), do: insert(:viewer_exclusion, user: me)
      other = insert(:activated_user, username: "one-too-many")
      assert {:error, :full} = Accounts.add_excluded_member(me, "one-too-many")
      refute Enum.any?(Accounts.list_viewer_exclusions(me), &(&1.excluded_user_id == other.id))
    end
  end

  describe "add_excluded_domain/2" do
    test "adds a normalized domain and refuses a duplicate" do
      me = owner()

      assert {:ok, x} =
               Accounts.add_excluded_domain(me, %{"domain" => "HTTPS://Employer.example/jobs"})

      assert x.domain == "employer.example"
      assert {:error, cs} = Accounts.add_excluded_domain(me, %{"domain" => "employer.example"})
      assert %{domain: _} = errors_on(cs)
    end

    test "returns a changeset error for a bad domain" do
      me = owner()
      assert {:error, cs} = Accounts.add_excluded_domain(me, %{"domain" => "not a domain"})
      refute cs.valid?
    end
  end

  describe "remove_viewer_exclusion/2" do
    test "removes only the owner's own row and is idempotent" do
      me = owner()
      other = owner()
      mine = insert(:viewer_exclusion, user: me, domain: "x.example")
      theirs = insert(:viewer_exclusion, user: other, domain: "y.example")

      # Cannot delete another member's row.
      assert :ok = Accounts.remove_viewer_exclusion(me, theirs.id)
      assert Accounts.viewer_exclusion_count(other) == 1

      assert :ok = Accounts.remove_viewer_exclusion(me, mine.id)
      assert Accounts.viewer_exclusion_count(me) == 0
      # Double submit is harmless.
      assert :ok = Accounts.remove_viewer_exclusion(me, mine.id)
    end
  end

  describe "viewer_excluded?/2" do
    test "never hides from the anonymous view or the owner" do
      me = owner()
      insert(:viewer_exclusion, user: me, domain: "x.example")
      refute Accounts.viewer_excluded?(me, nil)
      refute Accounts.viewer_excluded?(me, me)
    end

    test "hides from an excluded member, not from anyone else" do
      me = owner()
      boss = owner()
      stranger = owner()
      insert(:viewer_exclusion, user: me, excluded_user: boss, domain: nil)

      assert Accounts.viewer_excluded?(me, boss)
      refute Accounts.viewer_excluded?(me, stranger)
    end

    test "hides from a signed-in viewer whose confirmed email is at an excluded domain" do
      me = owner()
      insert(:viewer_exclusion, user: me, domain: "acme.example")

      colleague = owner()
      insert(:email, user: colleague, value: "COLLEAGUE@Acme.Example")

      outsider = owner()
      insert(:email, user: outsider, value: "someone@other.example")

      assert Accounts.viewer_excluded?(me, colleague)
      refute Accounts.viewer_excluded?(me, outsider)
    end

    test "an excluded domain also matches a subdomain, but never a look-alike host" do
      me = owner()
      insert(:viewer_exclusion, user: me, domain: "acme.example")

      sub = owner()
      insert(:email, user: sub, value: "recruiter@eu.mail.Acme.Example")

      lookalike = owner()
      insert(:email, user: lookalike, value: "someone@notacme.example")

      assert Accounts.viewer_excluded?(me, sub)
      refute Accounts.viewer_excluded?(me, lookalike)
    end

    test "a full block implies exclusion, with no list entry" do
      me = owner()
      nemesis = owner()
      # No viewer_exclusions row at all.
      {:ok, _} = Vutuv.Social.block_user(me, nemesis)
      assert Accounts.viewer_excluded?(me, nemesis)
      assert Accounts.viewer_exclusion_count(me) == 0
      # The block is directional: blocking me does not hide my fields from them.
      refute Accounts.viewer_excluded?(nemesis, me)
    end
  end

  describe "job_search_visibility/2 (base gate + exclusion)" do
    setup do
      me =
        owner(
          employment_status: "looking",
          employment_status_visibility: "everyone",
          desired_salary_min: 60_000,
          desired_salary_visibility: "everyone"
        )

      %{me: me}
    end

    test "everyone sees both fields when no one is excluded", %{me: me} do
      viewer = owner()
      assert %{employment_status: true, salary: true} = Accounts.job_search_visibility(me, viewer)
      # Anonymous crawler view too.
      assert %{employment_status: true, salary: true} = Accounts.job_search_visibility(me, nil)
    end

    test "an excluded viewer loses BOTH fields even at 'everyone'", %{me: me} do
      boss = owner()
      insert(:viewer_exclusion, user: me, excluded_user: boss, domain: nil)
      assert %{employment_status: false, salary: false} = Accounts.job_search_visibility(me, boss)
      # Still visible to the anonymous view (subtracting never touches it).
      assert %{employment_status: true, salary: true} = Accounts.job_search_visibility(me, nil)
    end
  end
end
