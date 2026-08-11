defmodule VutuvWeb.OrganizationMentionTest do
  @moduledoc """
  Naming an organization by its root handle in a body (issue #1336).

  It already **validated** — `Vutuv.Mentions` accepts an organization handle,
  so the post saved — but the renderer only ever looked up members, so `@acme`
  came out as plain text. A handle that is accepted as real and then rendered
  as if it were not is the worst of both.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias VutuvWeb.Markdown

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp handled_organization(handle) do
    {organization, _owner} = active_organization(unique_attrs(handle))
    {:ok, organization} = Organizations.claim_handle(organization, %{"username" => handle})
    organization
  end

  # Each page in a test needs its own domain: the claim refuses a second page
  # on a domain that is already taken.
  defp unique_attrs(handle),
    do: %{"name" => "#{handle} AG", "website_url" => "https://#{handle}.example"}

  defp render(body), do: body |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  test "an organization handle links to its page, titled with its name" do
    organization = handled_organization("acmegmbh")

    html = render("Wir arbeiten mit @acmegmbh zusammen.")

    assert html =~ ~s(href="/acmegmbh")
    assert html =~ ~s(class="mention")
    assert html =~ ~s(title="#{organization.name}")
  end

  test "a member handle still wins, and an unknown handle stays plain text" do
    member = insert(:activated_user, username: "einmitglied")
    _organization = handled_organization("eineseite")

    html = render("@einmitglied und @eineseite und @niemand")

    assert html =~ ~s(href="/#{member.username}")
    assert html =~ ~s(href="/eineseite")
    # An unknown handle is left exactly as typed — never a link to nowhere.
    assert html =~ "@niemand"
    refute html =~ ~s(href="/niemand")
  end

  test "a page nobody may see is not linked" do
    {organization, _owner} = active_organization(unique_attrs("verstecktag"))
    {:ok, organization} = Organizations.claim_handle(organization, %{"username" => "verstecktag"})
    {:ok, _} = Organizations.admin_set_frozen(organization, true)

    html = render("Was ist mit @verstecktag?")

    # Still readable as text, but no link into a page the reader would be
    # refused at.
    assert html =~ "@verstecktag"
    refute html =~ ~s(href="/verstecktag")
  end
end
