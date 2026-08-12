defmodule VutuvWeb.OrganizationAvatarControllerTest do
  @moduledoc """
  `GET /organizations/:slug/avatar.jpg` — a page's logo as a square JPEG, and
  the `icon` its ActivityPub actor document points at.

  Issue #1334 shipped the page actor without an icon, so a page federated
  faceless however good its logo was. Remote servers and link-preview scrapers
  fetch an avatar anonymously and do not decode the AVIF versions the site
  serves itself, which is why this derives a JPEG from the kept private
  original — the member endpoint's arrangement one to one.

  `async: false`: points the global `:uploads_dir_prefix` at a tmp dir and flips
  `:verify_organization_domains` for the organization helpers.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vix.Vips.Image, as: VipsImage
  alias Vutuv.Organizations
  alias Vutuv.Repo

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_org_logo_#{System.unique_integer([:positive])}")
    put_config(:uploads_dir_prefix, tmp)
    put_config(:verify_organization_domains, true)

    on_exit(fn ->
      File.rm_rf(tmp)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # `Application.get_env/2` cannot tell "absent" from "set to nil", so restoring
  # with it can write a real nil over a key that only had a default. Capture with
  # fetch_env/2 and restore the two cases apart.
  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp federating_page(handle \\ "acme") do
    owner = insert(:activated_user)

    page =
      active_organization_for(owner)
      |> Ecto.Changeset.change(%{fediverse_followers?: true, username: handle})
      |> Repo.update!()

    {page, owner}
  end

  defp with_logo({organization, owner}) do
    src = Path.join(System.tmp_dir!(), "logo_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(600, 400, color: [10, 120, 200])
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)

    {:ok, organization} = Organizations.store_logo(organization, owner, src, "logo.jpg")
    assert is_binary(organization.logo), "the logo was not released"
    organization
  end

  defp ap(conn), do: put_req_header(conn, "accept", "application/activity+json")

  test "serves the logo as a square, metadata-free JPEG", %{conn: conn} do
    page = federating_page() |> with_logo()

    conn = get(conn, "/organizations/#{page.slug}/avatar.jpg")

    assert conn.status == 200
    # No charset: a binary body must not claim one (binary_content_type_test.exs).
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert [cache] = get_resp_header(conn, "cache-control")
    assert cache =~ "public"

    {:ok, jpeg} = Image.from_binary(conn.resp_body)
    assert {Image.width(jpeg), Image.height(jpeg)} == {512, 512}

    {:ok, fields} = VipsImage.header_field_names(jpeg)
    assert Enum.filter(fields, &String.contains?(&1, "exif")) == []
  end

  test "the actor document names that JPEG as its icon, and the URL answers", %{conn: conn} do
    page = federating_page() |> with_logo()

    json = conn |> ap() |> get(~p"/organizations/#{page.slug}/actor") |> json_response(200)

    assert json["icon"]["type"] == "Image"
    assert json["icon"]["mediaType"] == "image/jpeg"
    assert json["icon"]["url"] =~ "/organizations/#{page.slug}/avatar.jpg"

    # The document is a promise to strangers: an icon URL that 404s reads as a
    # broken actor from outside, so walk the document rather than name the path.
    path = URI.parse(json["icon"]["url"]).path
    assert get(conn, path).status == 200
  end

  test "a page with no logo advertises no icon and answers 404", %{conn: conn} do
    {page, _owner} = federating_page()

    json = conn |> ap() |> get(~p"/organizations/#{page.slug}/actor") |> json_response(200)
    refute Map.has_key?(json, "icon")

    assert get(conn, "/organizations/#{page.slug}/avatar.jpg").status == 404
    assert get(conn, "/organizations/nobody-here/avatar.jpg").status == 404
  end

  test "a frozen page keeps its logo private", %{conn: conn} do
    page = federating_page() |> with_logo()
    assert get(conn, "/organizations/#{page.slug}/avatar.jpg").status == 200

    {:ok, page} = Organizations.admin_set_frozen(page, true)

    # The same gate every other byte of the page passes: while the page itself
    # is not public, neither is the picture on it.
    assert get(conn, "/organizations/#{page.slug}/avatar.jpg").status == 404
  end
end
