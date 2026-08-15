defmodule Vutuv.OrganizationPendingVerificationTest do
  @moduledoc """
  Finishing a domain claim without clicking (issue #1466): the report a failed
  check hands back, the clock every outcome stamps, and the background pass that
  picks a pending domain up on its own.

  `async: false` — the whole file holds `:verify_organization_domains` down and
  swaps `:organizations_dns_resolver`, and both are read by every other
  organization test in the suite.
  """

  use Vutuv.DataCase, async: false

  import Vutuv.Factory
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Organizations.OrganizationDomain

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    owner = insert(:activated_user)

    {:ok, %{organization: organization, domain: domain}} =
      Organizations.create_pending_organization(owner, valid_organization_attrs(), "dns")

    %{owner: owner, organization: organization, domain: domain}
  end

  # The zone answers, just not with our record — the shape that made the member
  # in #1466 re-read a zone file that was already correct.
  defp stub_other_records do
    Application.put_env(:vutuv, :organizations_dns_resolver, fn _host ->
      [[~c"v=spf1 mx -all"], [~c"google-site-verification=abc"]]
    end)
  end

  describe "check_domain/2" do
    test "reports every record it saw, so a wrong name is visible", ctx do
      stub_other_records()

      assert {:error, report} = Organizations.check_domain(ctx.organization, ctx.domain)
      assert report.method == "dns"
      assert "v=spf1 mx -all" in report.found
      assert "google-site-verification=abc" in report.found
      assert report.expected == Organizations.dns_txt_value(ctx.domain)
      assert ctx.domain.domain in report.names
      assert "_vutuv.#{ctx.domain.domain}" in report.names
    end

    test "stamps the clock on a failed check", ctx do
      stub_other_records()
      assert is_nil(ctx.domain.last_checked_at)

      assert {:error, _report} = Organizations.check_domain(ctx.organization, ctx.domain)
      assert Repo.get!(OrganizationDomain, ctx.domain.id).last_checked_at
    end

    test "activates the page on success", ctx do
      stub_dns(ctx.domain.verification_token)

      assert {:ok, organization} = Organizations.check_domain(ctx.organization, ctx.domain)
      assert organization.status == "active"
      assert Repo.get!(OrganizationDomain, ctx.domain.id).verified_at
    end

    test "is refused, and stamps nothing, while verification is off", ctx do
      Application.put_env(:vutuv, :verify_organization_domains, false)
      stub_dns(ctx.domain.verification_token)

      assert {:error, report} = Organizations.check_domain(ctx.organization, ctx.domain)
      assert report.disabled?
      assert is_nil(Repo.get!(OrganizationDomain, ctx.domain.id).last_checked_at)
    end
  end

  describe "pending_domains_due/1" do
    test "a domain nobody has checked yet is due", ctx do
      assert ctx.domain.id in Enum.map(Organizations.pending_domains_due(), & &1.id)
    end

    test "a domain checked a moment ago is not due again immediately", ctx do
      stub_other_records()
      {:error, _report} = Organizations.check_domain(ctx.organization, ctx.domain)

      refute ctx.domain.id in Enum.map(Organizations.pending_domains_due(), & &1.id)
    end

    test "an old pending claim is given up on rather than checked forever", ctx do
      long_ago =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.truncate(:second)
        |> NaiveDateTime.add(-400 * 86_400)

      ctx.domain
      |> Ecto.Changeset.change(inserted_at: long_ago, last_checked_at: long_ago)
      |> Repo.update!()

      refute ctx.domain.id in Enum.map(Organizations.pending_domains_due(), & &1.id)
    end

    test "an already verified domain belongs to the weekly re-check, not here", ctx do
      stub_dns(ctx.domain.verification_token)
      {:ok, _organization} = Organizations.check_domain(ctx.organization, ctx.domain)

      refute ctx.domain.id in Enum.map(Organizations.pending_domains_due(), & &1.id)
    end
  end

  describe "check_pending_domains/0" do
    test "verifies the page and tells its owners", ctx do
      stub_dns(ctx.domain.verification_token)
      flush_emails()

      assert Organizations.check_pending_domains() == 1
      assert Organizations.get_organization!(ctx.organization.id).status == "active"

      subjects = flush_emails() |> Enum.map(& &1.subject)
      assert Enum.any?(subjects, &(&1 =~ "verifiziert" or &1 =~ "verified"))
    end

    test "a still-missing record leaves the domain out of the very next pass", ctx do
      stub_other_records()

      assert Organizations.check_pending_domains() == 0
      # The starvation guard: an unworkable item must leave the due set, or it
      # holds the front of every batch for ever (oldest-first ordering).
      refute ctx.domain.id in Enum.map(Organizations.pending_domains_due(), & &1.id)
      assert Organizations.get_organization!(ctx.organization.id).status == "pending"
    end

    test "does nothing at all while verification is off", ctx do
      Application.put_env(:vutuv, :verify_organization_domains, false)
      stub_dns(ctx.domain.verification_token)

      assert Organizations.check_pending_domains() == 0
      assert Organizations.get_organization!(ctx.organization.id).status == "pending"
    end
  end
end
