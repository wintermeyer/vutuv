defmodule VutuvWeb.LinkThumbArrivesTest do
  @moduledoc """
  A link preview tile changes while somebody is looking at it, and the page
  follows without a reload (issue #1928) — the two surfaces issue #1927 left
  out.

  `<.link_thumb>` draws the same three states on four surfaces. A post's card
  learned to hear about all three; a **profile's** Links card and an
  **organization page's** homepage capture did not, so a member watched a grey
  tile that had been a real picture for two minutes. Both moments count: the
  capture landing is when the mosaic preview appears (issue #1720), the verdict
  is when the picture itself does, and a refusal deletes the very file the
  mosaic names.

  `async: false` — flips `:moderate_images` and `:uploads_dir_prefix`, which
  the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.Factory
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.Organizations.OrganizationScreenshot
  alias Vutuv.Organizations.Screenshots
  alias Vutuv.PageScreenshot
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo
  alias Vutuv.Screenshot

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_link_thumb_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    put_config(:uploads_dir_prefix, tmp)
    put_config(:moderate_images, true)

    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp}
  end

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

  # A real, decodable image where the browser would have left its framed webp:
  # the store runs libvips over it and derives the mosaic from those pixels, so
  # a fake binary would test nothing.
  defp framed_capture(tmp) do
    path = Path.join(tmp, "framed-#{System.unique_integer([:positive])}.webp")
    {:ok, image} = Image.new(400, 264, color: [30, 90, 160])
    {:ok, _} = Image.write(image, path)
    path
  end

  # The profile queue's Chromium seam: only the browser step is stubbed, so the
  # store, the scan enqueue and the announcement all run for real.
  defp capture_link(tmp),
    do: PageScreenshot.capture_due(capture: fn _url -> {:ok, framed_capture(tmp)} end)

  defp scan(kind, subject) do
    %ImageScan{
      kind: kind,
      subject_id: subject.id,
      fingerprint: subject.screenshot,
      owner_user_id: Map.get(subject, :user_id)
    }
  end

  describe "a profile's Links card" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      url = insert(:url, user: user, value: "https://blog.example/entry")
      {:ok, conn: conn, user: user, url: url}
    end

    test "the capture lands and the tile stops being grey", %{
      conn: conn,
      user: user,
      url: url,
      tmp: tmp
    } do
      {:ok, view, _html} = live(conn, ~p"/#{user}")
      assert has_element?(view, ~s([data-link-thumb="pending"]))

      capture_link(tmp)

      # The gate still holds the picture, so what arrives is the mosaic — which
      # is the point: there was nothing to look at before, and now there is.
      assert has_element?(view, ~s([data-link-thumb="pixelated"]))
      assert Repo.get!(Url, url.id).screenshot_moderation == "pending"
    end

    test "the verdict releases it and the picture swaps in", %{
      conn: conn,
      user: user,
      url: url,
      tmp: tmp
    } do
      {:ok, view, _html} = live(conn, ~p"/#{user}")
      capture_link(tmp)
      assert has_element?(view, ~s([data-link-thumb="pixelated"]))

      assert :ok = ImageSubjects.apply_approved(scan("url_screenshot", Repo.get!(Url, url.id)))

      assert has_element?(view, ~s([data-link-thumb="shot"]))
      refute has_element?(view, ~s([data-link-thumb="pixelated"]))
    end

    test "a refused capture is announced too, so the mosaic goes", %{
      conn: conn,
      user: user,
      url: url,
      tmp: tmp
    } do
      # The rejection deletes the very file the mosaic on an open page names, so
      # a page nobody tells goes on asking for it and draws a broken image.
      {:ok, view, _html} = live(conn, ~p"/#{user}")
      capture_link(tmp)
      assert has_element?(view, ~s([data-link-thumb="pixelated"]))

      assert :ok = ImageSubjects.apply_rejected(scan("url_screenshot", Repo.get!(Url, url.id)))

      refute has_element?(view, ~s([data-link-thumb="pixelated"]))
      assert has_element?(view, ~s([data-link-thumb="pending"]))
    end
  end

  describe "an organization page's homepage capture" do
    setup do
      put_config(:verify_organization_domains, true)
      on_exit(fn -> Application.delete_env(:vutuv, :organizations_dns_resolver) end)

      {organization, _owner} = active_organization()
      {:ok, organization: organization}
    end

    test "the capture lands and the tile appears above the fold", %{
      conn: conn,
      organization: organization,
      tmp: tmp
    } do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}")
      # Nothing is drawn before the capture: a lone grey rectangle reads as a
      # broken image, so the tile is absent rather than empty.
      refute has_element?(view, "[data-organization-screenshot]")

      Screenshots.deliver_due(force: true, capture: capture(tmp))

      assert has_element?(view, ~s([data-link-thumb="pixelated"]))
      assert Repo.one(OrganizationScreenshot).moderation == "pending"
    end

    test "the verdict releases it and the picture swaps in", %{
      conn: conn,
      organization: organization,
      tmp: tmp
    } do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}")
      Screenshots.deliver_due(force: true, capture: capture(tmp))
      assert has_element?(view, ~s([data-link-thumb="pixelated"]))

      assert :ok =
               ImageSubjects.apply_approved(
                 scan("organization_screenshot", Repo.one(OrganizationScreenshot))
               )

      assert has_element?(view, ~s([data-link-thumb="shot"]))
      refute has_element?(view, ~s([data-link-thumb="pixelated"]))
    end

    test "a refused capture takes the tile away again", %{
      conn: conn,
      organization: organization,
      tmp: tmp
    } do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}")
      Screenshots.deliver_due(force: true, capture: capture(tmp))
      assert has_element?(view, ~s([data-link-thumb="pixelated"]))

      assert :ok =
               ImageSubjects.apply_rejected(
                 scan("organization_screenshot", Repo.one(OrganizationScreenshot))
               )

      refute has_element?(view, "[data-organization-screenshot]")
    end
  end

  # The organization queue's Chromium seam, storing a real picture the way the
  # browser path stores one — the mosaic is written from those bytes.
  defp capture(tmp) do
    fn job ->
      upload = %Plug.Upload{
        filename: "framed.webp",
        path: framed_capture(tmp),
        content_type: "image/webp"
      }

      {:ok, stored} = Screenshot.store({upload, job})
      {:ok, %{screenshot: stored, width: 400, height: 264}}
    end
  end
end
