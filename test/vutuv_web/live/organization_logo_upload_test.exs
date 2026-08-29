defmodule VutuvWeb.OrganizationLogoUploadTest do
  @moduledoc """
  The logo field on `/organizations/:slug/edit` (`VutuvWeb.OrganizationLive.Edit`).

  PNG has always been on the whitelist, but three outcomes left the page
  silent, so a member whose picture never appeared could only conclude the
  format was refused: a file over the size cap (a PNG export passes it far
  sooner than a JPEG) raises an error on the *entry*, which the form never
  rendered; a file the encoder cannot read was swallowed by `consume_logo` and
  still flashed "updated"; and an image held by moderation leaves the old logo
  in place with nothing to say why.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.OrganizationImageStore
  alias Vutuv.Organizations
  alias Vutuv.Organizations.OrganizationImage
  alias Vutuv.Repo
  alias Vutuv.Uploads.Spec

  setup %{conn: conn} do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
      Application.put_env(:vutuv, :moderate_images, false)
    end)

    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)

    {:ok, conn: conn, owner: owner, organization: organization}
  end

  defp edit_live(conn, organization) do
    conn = get(conn, "/organizations/#{organization.slug}/edit")
    {:ok, live, _html} = live(conn)
    live
  end

  defp png do
    {:ok, img} = Image.new(90, 60, color: [30, 90, 160])
    {:ok, binary} = Image.write(img, :memory, suffix: ".png")
    binary
  end

  defp attach(live, entry) do
    file_input(live, "#organization-form", :logo, [entry])
  end

  # Saving navigates away, so what the member is told lives in the flash the
  # redirect carries, not in the re-rendered form.
  defp save(live) do
    live
    |> form("#organization-form", organization: %{})
    |> render_submit()

    {_path, flash} = assert_redirect(live)
    flash
  end

  defp logo_image(organization) do
    Repo.get_by(OrganizationImage, organization_id: organization.id)
  end

  test "a PNG becomes the logo", %{conn: conn, organization: organization} do
    live = edit_live(conn, organization)
    content = png()

    input =
      attach(live, %{
        name: "logo.png",
        content: content,
        type: "image/png",
        size: byte_size(content)
      })

    render_upload(input, "logo.png")
    save(live)

    image = logo_image(organization)
    assert image.content_type == "image/png"
    assert Organizations.get_organization!(organization.id).logo == image.token
  end

  @svg """
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
    <rect width="64" height="64" rx="12" fill="#1b1408"/>
    <circle cx="22" cy="22" r="10" fill="#e2a634"/>
  </svg>
  """

  # A vector logo carries no pixels, so what lands on disk is what the server
  # rendered — at the widest version's size, not the 64px the file names.
  test "an SVG is rasterised into a usable logo", %{conn: conn, organization: organization} do
    live = edit_live(conn, organization)

    input =
      attach(live, %{name: "logo.svg", content: @svg, type: "image/svg+xml"})

    render_upload(input, "logo.svg")
    save(live)

    image = logo_image(organization)
    assert image.content_type == "image/svg+xml"
    assert image.width == Spec.svg_raster_size()
    assert Organizations.get_organization!(organization.id).logo == image.token
    assert OrganizationImageStore.version_path(image.token, "large")
  end

  # Which markup is refused is `Vutuv.Uploads.Spec`'s business and is covered in
  # its own test; what this page owes the member is a sentence about it.
  test "an SVG the renderer gate refuses says so", %{conn: conn, organization: organization} do
    live = edit_live(conn, organization)

    hostile = String.replace(@svg, "<rect", ~s|<script>window.x = 1</script><rect|)
    input = attach(live, %{name: "logo.svg", content: hostile, type: "image/svg+xml"})

    render_upload(input, "logo.svg")
    flash = save(live)

    assert flash["error"] =~ "could not be used"
    refute logo_image(organization)
  end

  test "a file over the size cap says so", %{conn: conn, organization: organization} do
    live = edit_live(conn, organization)

    input =
      attach(live, %{
        name: "logo.png",
        content: :binary.copy("x", OrganizationImageStore.max_filesize() + 1),
        type: "image/png"
      })

    render_upload(input, "logo.png")

    assert render(live) =~ "larger than"
  end

  test "a valid form does not claim it has errors", %{conn: conn, organization: organization} do
    live = edit_live(conn, organization)

    # The file input sits inside the form, so choosing a logo fires
    # phx-change="validate" with the untouched fields — the same event a
    # keystroke sends. It used to raise the "check the fields marked in red"
    # banner over a form with nothing marked in red at all, which is how a
    # member picking a PNG was told their file had been refused.
    html =
      live
      |> form("#organization-form", organization: %{name: organization.name})
      |> render_change()

    refute html =~ "Please check the fields marked in red"
  end

  test "a real field error still raises the banner", %{conn: conn, organization: organization} do
    live = edit_live(conn, organization)

    html =
      live
      |> form("#organization-form", organization: %{name: ""})
      |> render_change()

    assert html =~ "Please check the fields marked in red"
  end

  test "a picture the encoder cannot read says so instead of flashing success", %{
    conn: conn,
    organization: organization
  } do
    live = edit_live(conn, organization)
    content = String.duplicate("not a picture", 100)

    input =
      attach(live, %{
        name: "logo.png",
        content: content,
        type: "image/png",
        size: byte_size(content)
      })

    render_upload(input, "logo.png")
    flash = save(live)

    assert flash["error"] =~ "could not be used"
    refute flash["info"]
    refute logo_image(organization)
  end

  test "a logo waiting for the image scan says so", %{conn: conn, organization: organization} do
    Application.put_env(:vutuv, :moderate_images, true)

    live = edit_live(conn, organization)
    content = png()

    input =
      attach(live, %{
        name: "logo.png",
        content: content,
        type: "image/png",
        size: byte_size(content)
      })

    render_upload(input, "logo.png")
    flash = save(live)

    assert flash["info"] =~ "being checked"
    assert logo_image(organization).moderation == "pending"
    assert Organizations.get_organization!(organization.id).logo == organization.logo
  end

  # The hint is built from the store's whitelist, so it names SVG exactly on the
  # installations that can rasterise one.
  test "the form names the formats and the size cap", %{conn: conn, organization: organization} do
    conn = get(conn, "/organizations/#{organization.slug}/edit")
    html = html_response(conn, 200)

    assert html =~ "JPEG, PNG"
    assert html =~ "up to 4 MB"
    assert html =~ "SVG" == Spec.svg_supported?()
  end

  test "the hint is translated for a German visitor", %{conn: conn, organization: organization} do
    conn =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de")
      |> get("/organizations/#{organization.slug}/edit")

    assert html_response(conn, 200) =~ "bis 4 MB"
  end
end
