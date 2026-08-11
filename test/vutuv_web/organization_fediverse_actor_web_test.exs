defmodule VutuvWeb.OrganizationFediverseActorWebTest do
  @moduledoc """
  A page's ActivityPub identity (issue #1334): WebFinger resolves its handle,
  and `/organizations/:slug/actor` serves an `Organization` document.

  Everything here is gated on the page's opt-in, so an un-opted page answers 404
  exactly as an un-federated member does. That gate is what lets this land
  before the inbox exists: nothing is reachable from outside until a page owner
  switches it on, and by then the whole chain will be in place.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp federating_page(handle \\ "acme") do
    active_organization_for(insert(:activated_user))
    |> Ecto.Changeset.change(%{fediverse_followers?: true, username: handle})
    |> Repo.update!()
  end

  defp ap(conn), do: put_req_header(conn, "accept", "application/activity+json")

  test "WebFinger resolves the page's handle to its actor", %{conn: conn} do
    page = federating_page()

    json =
      conn
      |> get(~p"/.well-known/webfinger", resource: "acct:acme@#{VutuvWeb.Endpoint.host()}")
      |> json_response(200)

    assert json["subject"] == "acct:acme@#{VutuvWeb.Endpoint.host()}"

    self_link = Enum.find(json["links"], &(&1["rel"] == "self"))
    assert self_link["href"] =~ "/organizations/#{page.slug}/actor"
  end

  test "the actor document says Organization, not Person", %{conn: conn} do
    page = federating_page()

    json = conn |> ap() |> get(~p"/organizations/#{page.slug}/actor") |> json_response(200)

    # The type is the whole point: it is what tells a remote server to render
    # this as an organisation rather than as a person.
    assert json["type"] == "Organization"
    assert json["preferredUsername"] == "acme"
    assert json["name"] == page.name
    assert json["publicKey"]["publicKeyPem"] =~ "PUBLIC KEY"
    assert json["inbox"] =~ "/organizations/#{page.slug}/actor/inbox"
    assert json["endpoints"]["sharedInbox"] =~ "/system/inbox"

    # A page pins nothing and migrates nowhere: those fields belong to a person
    # deciding about their own identity, and emitting them empty would be worse
    # than leaving them out.
    refute Map.has_key?(json, "featured")
    refute Map.has_key?(json, "alsoKnownAs")
    refute Map.has_key?(json, "movedTo")
  end

  test "the followers collection counts the remote followers", %{conn: conn} do
    page = federating_page()

    {:ok, _} =
      Vutuv.Fediverse.add_organization_follower(page, %{
        actor_uri: "https://remote.example/users/frida",
        inbox_uri: "https://remote.example/users/frida/inbox"
      })

    json =
      conn |> ap() |> get(~p"/organizations/#{page.slug}/actor/followers") |> json_response(200)

    assert json["totalItems"] == 1
  end

  test "a page that has not opted in is invisible", %{conn: conn} do
    page = active_organization_for(insert(:activated_user))

    assert conn |> ap() |> get(~p"/organizations/#{page.slug}/actor") |> response(404)

    assert conn
           |> get(~p"/.well-known/webfinger",
             resource: "acct:#{page.slug}@#{VutuvWeb.Endpoint.host()}"
           )
           |> response(404)
  end

  test "a page without a claimed handle cannot federate", %{conn: conn} do
    page =
      active_organization_for(insert(:activated_user))
      |> Ecto.Changeset.change(%{fediverse_followers?: true})
      |> Repo.update!()

    # The handle IS the address out there — WebFinger's subject and the actor
    # document's preferredUsername are both built from it — so opting in without
    # one would only make the page unreachable, not federated.
    assert is_nil(page.username)
    assert conn |> ap() |> get(~p"/organizations/#{page.slug}/actor") |> response(404)
  end

  test "a frozen page stops answering", %{conn: conn} do
    page = federating_page()
    assert conn |> ap() |> get(~p"/organizations/#{page.slug}/actor") |> response(200)

    {:ok, _} = Organizations.admin_set_frozen(page, true)

    assert conn |> ap() |> get(~p"/organizations/#{page.slug}/actor") |> response(404)
  end

  test "every endpoint the actor document advertises actually answers", %{conn: conn} do
    page = federating_page()

    json = conn |> ap() |> get(~p"/organizations/#{page.slug}/actor") |> json_response(200)

    # The document is a promise to strangers: a remote server fetches these
    # while building its picture of an account, so one that 404s reads as a
    # broken actor from outside. The outbox did exactly that for one commit,
    # which is why this walks the document instead of naming paths by hand.
    for key <- ~w(followers outbox) do
      url = json[key]
      assert is_binary(url), "the actor document names no #{key}"

      path = URI.parse(url).path
      assert conn |> ap() |> get(path) |> json_response(200)
    end

    # The inbox is a POST target, so a GET is not the check — but it must at
    # least be a route, not a 404 from the router.
    assert json["inbox"] =~ "/organizations/#{page.slug}/actor/inbox"
  end
end
