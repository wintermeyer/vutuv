defmodule VutuvWeb.OrganizationScreenshotRenderTest do
  @moduledoc """
  What an organization page shows of its homepage capture: the picture once the
  AI scan has released it, the pixelated stand-in while the scan is judging it,
  and nothing at all while the queue has not got there — a lone card that is
  only the bundled grey rectangle reads as a broken image.

  Also pins where it sits — the header card's banner, above the page's name,
  not the rail card it replaced — and the shape beside it: the proven domain is
  the small ✓ next to the website, not a pill of its own on the badge row.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Moderation.Pixelation
  alias Vutuv.Organizations.OrganizationScreenshot
  alias Vutuv.Organizations.Screenshots
  alias Vutuv.Repo
  alias Vutuv.Uploads

  @hash "0123456789ab"

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # A captured, released job whose thumb really is on disk — `showable?/1` reads
  # the resolved URL, so a row alone is not a picture.
  defp captured(organization, attrs \\ []) do
    job = Screenshots.for_organization(organization)

    {:ok, job} =
      job
      |> Ecto.Changeset.change(
        Keyword.merge(
          [status: "ready", screenshot: "#{@hash}.avif", moderation: "approved"],
          attrs
        )
      )
      |> Repo.update()

    job
  end

  defp write_file(%OrganizationScreenshot{} = job, filename) do
    dir = Uploads.disk_dir("screenshots/#{job.id}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), "not really an image")
    on_exit(fn -> File.rm_rf(Uploads.disk_dir("screenshots/#{job.id}")) end)
    job
  end

  defp page(conn, organization),
    do: conn |> get(~p"/organizations/#{organization.slug}") |> html_response(200)

  # Source-order position of `needle`, so a test can pin that one piece of
  # markup comes before another.
  defp at(html, needle) do
    assert {start, _length} = :binary.match(html, needle)
    start
  end

  describe "the header banner" do
    test "shows the capture once it is released, above the page's name", %{conn: conn} do
      {organization, _owner} = active_organization()
      organization |> captured() |> write_file("thumb-#{@hash}.avif")

      html = page(conn, organization)

      assert html =~ "data-organization-screenshot"
      assert html =~ ~s(data-link-thumb="shot")
      assert html =~ "/screenshots/"

      # Where it sits is half the point — see the header-card comment in
      # `VutuvWeb.OrganizationLive.Show`. The rail renders after the whole main
      # column, so back in the rail this is 2,300px down a phone's page.
      assert at(html, "data-organization-screenshot") < at(html, "<h1")
    end

    test "shows nothing while the capture is still queued", %{conn: conn} do
      {organization, _owner} = active_organization()

      html = page(conn, organization)

      refute html =~ "data-organization-screenshot"
    end

    test "shows nothing when the row names a file that is not on disk", %{conn: conn} do
      {organization, _owner} = active_organization()
      captured(organization)

      html = page(conn, organization)

      refute html =~ "data-organization-screenshot"
    end

    test "shows the pixelated stand-in while the AI scan is judging it", %{conn: conn} do
      {organization, _owner} = active_organization()

      organization
      |> captured(moderation: "pending")
      |> write_file(Pixelation.filename(@hash))

      html = page(conn, organization)

      assert html =~ "data-organization-screenshot"
      assert html =~ ~s(data-link-thumb="pixelated")
      # …and the badge that says why it looks like that: two blurred cells with
      # no word for them read as a broken picture.
      assert html =~ Pixelation.filename(@hash)
    end
  end

  describe "the proven domain" do
    test "rides beside the website as a ✓, not as a badge of its own", %{conn: conn} do
      {organization, _owner} = active_organization()

      html = page(conn, organization)

      # `<.verified_mark>` is icon-only, so the domain lives in the glyph's
      # label. The pill it replaced put the same sentence in visible text on the
      # badge row and marked its own svg `aria-hidden`, so this line is the one
      # that tells the two apart.
      assert html =~ ~s(aria-label="Verified via acme.example")

      # And it stands next to the website, not above it in the badge row.
      body = html |> String.split("<h1", parts: 2) |> List.last()
      assert at(body, ~s(href="https://acme.example")) < at(body, "Verified via acme.example")
    end

    test "a page whose primary domain is not proven yet wears no ✓", %{conn: conn} do
      owner = insert(:activated_user)

      {:ok, %{organization: organization}} =
        Vutuv.Organizations.create_pending_organization(
          owner,
          valid_organization_attrs(),
          "dns"
        )

      # A pending page is invisible to the public and shows its owner the
      # verification panel; an admin is the one viewer who reaches the public
      # rendering of it.
      {conn, _admin} = create_and_login_admin(conn)

      html =
        conn
        |> get(~p"/organizations/#{organization.slug}")
        |> html_response(200)

      refute html =~ "Verified via"
    end
  end
end
