defmodule VutuvWeb.OrganizationVerificationUxTest do
  @moduledoc """
  What the member sees while a domain claim is still open (issue #1466): the
  report a failed check leaves on the page, the promise that something else is
  looking too, and the way back to the panel from the settings hub.

  `async: false` — the file holds `:verify_organization_domains` down and swaps
  `:organizations_dns_resolver`, both read across the whole organization suite.
  """

  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization

  @valid Vutuv.OrganizationsHelpers.valid_organization_attrs()

  setup %{conn: conn} do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    {conn, user} = create_and_login_user(conn)

    {:ok, %{organization: organization, domain: domain}} =
      Organizations.create_pending_organization(user, @valid, "dns")

    %{conn: conn, user: user, organization: organization, domain: domain}
  end

  defp stub_records(records) do
    Application.put_env(:vutuv, :organizations_dns_resolver, fn _host -> records end)
  end

  describe "the verification panel" do
    test "a failed check names what it looked for and what was there", ctx do
      stub_records([[~c"v=spf1 mx -all"]])

      {:ok, view, _html} = live(ctx.conn, ~p"/organizations/#{ctx.organization.slug}")
      html = view |> element("#verify-domain") |> render_click()

      assert html =~ "v=spf1 mx -all"
      assert html =~ Organizations.dns_txt_value(ctx.domain)
      assert has_element?(view, "#verify-domain-report")
    end

    test "an empty zone says so rather than saying nothing", ctx do
      stub_records([])

      {:ok, view, _html} = live(ctx.conn, ~p"/organizations/#{ctx.organization.slug}")
      view |> element("#verify-domain") |> render_click()

      assert view |> element("[data-check-found]") |> render() =~ "No TXT record"
    end

    # The reported bug: the first click showed a toast and every click after it
    # looked like nothing at all, because an identical flash renders no diff.
    # The report is an assign, so a second attempt always answers on the page.
    test "a second attempt answers too, and answers with the new facts", ctx do
      stub_records([[~c"v=spf1 mx -all"]])

      {:ok, view, _html} = live(ctx.conn, ~p"/organizations/#{ctx.organization.slug}")
      view |> element("#verify-domain") |> render_click()

      stub_records([[~c"google-site-verification=abc"]])
      html = view |> element("#verify-domain") |> render_click()

      assert html =~ "google-site-verification=abc"
      refute html =~ "v=spf1 mx -all"
    end

    test "the button says it is busy while the check runs", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/organizations/#{ctx.organization.slug}")

      assert view |> element("#verify-domain") |> render() =~ "phx-disable-with"
    end

    test "the panel promises the background check, so the page can be closed", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/organizations/#{ctx.organization.slug}")

      assert has_element?(view, "[data-check-reassurance]")
    end

    test "a successful check clears the report and publishes the page", ctx do
      stub_dns(ctx.domain.verification_token)

      {:ok, view, _html} = live(ctx.conn, ~p"/organizations/#{ctx.organization.slug}")
      view |> element("#verify-domain") |> render_click()

      refute has_element?(view, "#verify-domain-report")
      assert Repo.get!(Organization, ctx.organization.id).status == "active"
    end

    test "an open page goes live by itself when the background pass finishes", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/organizations/#{ctx.organization.slug}")
      assert has_element?(view, "#verify-domain")

      stub_dns(ctx.domain.verification_token)
      assert Organizations.check_pending_domains() == 1

      # No reload, no click: the pass broadcasts on the page's own topic, and
      # this render is the round trip that lets the view handle it.
      assert render(view) =~ ctx.organization.name
      refute has_element?(view, "#verify-domain")
    end
  end

  # `mix gettext.extract --merge` fuzzy-filled three of these from unrelated
  # strings: "Finish verification" came back as "Prüfung ausstehend" (the status
  # label) and the mail subject "…is verified" as "…ist nicht mehr öffentlich"
  # (is no longer public), the exact opposite of what it announces. Nothing
  # fails the build on a fuzzy entry, so the German is asserted by name.
  describe "the German rendering" do
    test "the panel explains itself in German", ctx do
      stub_records([[~c"v=spf1 mx -all"]])

      {:ok, view, _html} =
        ctx.conn
        |> Phoenix.ConnTest.recycle()
        |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
        |> live(~p"/organizations/#{ctx.organization.slug}")

      html = view |> element("#verify-domain") |> render_click()

      assert html =~ "Noch nicht gefunden"
      assert html =~ "Was dort im Moment veröffentlicht ist:"
      assert html =~ "Wird geprüft …"
      assert html =~ "schicken Ihnen eine E-Mail"
    end

    test "the settings hub names the remaining step in German", ctx do
      html =
        ctx.conn
        |> Phoenix.ConnTest.recycle()
        |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
        |> get(~p"/settings/organizations")
        |> html_response(200)

      assert html =~ "Verifizierung abschließen"
    end

    test "the background pass announces a page that is live, not one that is gone", ctx do
      # The mail follows the owner's own locale, not the request's — nobody is
      # making a request when this one is sent.
      ctx.user |> Ecto.Changeset.change(locale: "de") |> Repo.update!()
      stub_dns(ctx.domain.verification_token)
      flush_emails()

      assert Organizations.check_pending_domains() == 1

      assert Enum.any?(flush_emails(), fn email ->
               email.subject == "Ihre Organisationsseite auf vutuv ist verifiziert"
             end)
    end
  end

  describe "finding the way back" do
    test "the settings hub offers the pending page its one remaining step", ctx do
      html = ctx.conn |> get(~p"/settings/organizations") |> html_response(200)

      assert html =~ "data-finish-verification"
      assert html =~ ~s(/organizations/#{ctx.organization.slug}")
    end

    test "an active page gets the plain manage link instead", ctx do
      stub_dns(ctx.domain.verification_token)
      {:ok, _organization} = Organizations.check_domain(ctx.organization, ctx.domain)

      html = ctx.conn |> get(~p"/settings/organizations") |> html_response(200)

      refute html =~ "data-finish-verification"
      assert html =~ ~s(/organizations/#{ctx.organization.slug}/edit")
    end
  end
end
