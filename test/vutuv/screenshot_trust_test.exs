defmodule Vutuv.ScreenshotTrustTest do
  @moduledoc """
  The trusted-sites list: link screenshots of these sites skip the AI image
  scan and show at once. Covers the entry grammar (and the two ways it is
  deliberately narrower than the blocklist's), the rule that every page the
  browser showed must be trusted, and what the three capture queues do with a
  trusted capture: release it on the spot, with no scan row and nothing left
  in quarantine.

  `async: false` — the queue tests flip `:moderate_images`,
  `:uploads_dir_prefix` and `:verify_organization_domains`, which the SQL
  sandbox does not roll back (the same flags the other screenshot-queue tests
  flip).
  """
  use Vutuv.DataCase, async: false

  import Vutuv.ExternalTagHelpers, only: [put_config: 2]
  import Vutuv.OrganizationsHelpers
  import Vutuv.PostsHelpers

  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.Pixelation
  alias Vutuv.Organizations.Screenshots, as: OrganizationScreenshots
  alias Vutuv.PageScreenshot
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots, as: PostScreenshots
  alias Vutuv.Profiles.Url
  alias Vutuv.Screenshot
  alias Vutuv.ScreenshotTrust

  defp trust(hosts) do
    for host <- hosts do
      {:ok, _host} = ScreenshotTrust.create_host(%{"host" => host})
    end
  end

  describe "entries" do
    test "a pasted address is stored as its bare host" do
      assert {:ok, host} =
               ScreenshotTrust.create_host(%{"host" => "  HTTPS://www.Tagesschau.de/  "})

      assert host.host == "tagesschau.de"
    end

    test "a wildcard entry keeps its star" do
      assert {:ok, host} = ScreenshotTrust.create_host(%{"host" => "*.tagesschau.de"})
      assert host.host == "*.tagesschau.de"
    end

    test "an address with a path is refused, not cut down to its host" do
      # Trust is a statement about who runs a site, so a path would narrow
      # nothing — and silently widening a pasted article URL to the whole site
      # is the kind of surprise a safety exemption must not spring.
      assert {:error, changeset} =
               ScreenshotTrust.create_host(%{
                 "host" => "https://www.tagesschau.de/inland/story-100.html"
               })

      assert %{host: [_message]} = errors_on(changeset)
    end

    test "a line that names no site is refused" do
      for junk <- ["", "https://", "tagesschau", "*.de", "tages schau.de", "user@tagesschau.de"] do
        assert {:error, changeset} = ScreenshotTrust.create_host(%{"host" => junk}),
               "#{inspect(junk)} was accepted"

        assert %{host: [_message]} = errors_on(changeset)
      end
    end

    test "the same site cannot be listed twice" do
      trust(["tagesschau.de"])

      assert {:error, changeset} =
               ScreenshotTrust.create_host(%{"host" => "www.tagesschau.de"})

      assert %{host: [_message]} = errors_on(changeset)
    end
  end

  describe "trusted?/1" do
    test "a bare entry covers the site and its www. alias, on any path" do
      trust(["tagesschau.de"])

      assert ScreenshotTrust.trusted?("https://tagesschau.de")
      assert ScreenshotTrust.trusted?("https://www.tagesschau.de/inland/story-100.html")
      assert ScreenshotTrust.trusted?("http://WWW.TAGESSCHAU.DE/?utm_source=x#top")
    end

    test "a bare entry does not cover other subdomains" do
      # The asymmetry against the blocklist, where `heise.de` covers every
      # subdomain because blocking too little is the worse mistake. Here it is
      # trusting too much: on a platform every subdomain belongs to somebody
      # else (substack.com, github.io), and one entry would wave all of them
      # past the scan.
      trust(["substack.com"])

      refute ScreenshotTrust.trusted?("https://anyone.substack.com/p/post")
    end

    test "an entry stops at the label boundary" do
      trust(["tagesschau.de"])

      refute ScreenshotTrust.trusted?("https://nottagesschau.de/")
      refute ScreenshotTrust.trusted?("https://tagesschau.de.evil.example/")
    end

    test "a wildcard entry covers the site and every subdomain" do
      trust(["*.tagesschau.de"])

      assert ScreenshotTrust.trusted?("https://tagesschau.de/")
      assert ScreenshotTrust.trusted?("https://www.tagesschau.de/")
      assert ScreenshotTrust.trusted?("https://meta.tagesschau.de/id/1")
      assert ScreenshotTrust.trusted?("https://a.b.tagesschau.de/")
      refute ScreenshotTrust.trusted?("https://nottagesschau.de/")
    end

    test "anything without a host is not trusted" do
      trust(["tagesschau.de"])

      refute ScreenshotTrust.trusted?("about:blank")
      refute ScreenshotTrust.trusted?("chrome-error://chromewebdata/")
      refute ScreenshotTrust.trusted?(nil)
    end
  end

  describe "rendered_trusted?/1" do
    test "every page the browser showed has to be trusted" do
      trust(["tagesschau.de"])

      assert ScreenshotTrust.rendered_trusted?(["https://www.tagesschau.de/story"])

      # A trusted page that navigated on to another site: the picture may show
      # the other one, so it is scanned like any capture.
      refute ScreenshotTrust.rendered_trusted?([
               "https://www.tagesschau.de/story",
               "https://elsewhere.example/"
             ])
    end

    test "a capture with no recorded page is not trusted" do
      trust(["tagesschau.de"])

      refute ScreenshotTrust.rendered_trusted?([])
    end
  end

  describe "the capture queues" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "vutuv_trust_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      put_config(:uploads_dir_prefix, tmp)
      put_config(:moderate_images, true)
      on_exit(fn -> File.rm_rf(tmp) end)

      {:ok, tmp: tmp}
    end

    test "a trusted capture is stored straight into the served tree", %{tmp: tmp} do
      held = insert(:url, value: "https://blog.example/entry")
      trusted = insert(:url, value: "https://www.tagesschau.de/story")

      {:ok, held_file} = Screenshot.store({upload(tmp, held), held})
      {:ok, file} = Screenshot.store({upload(tmp, trusted), trusted}, trusted: true)

      assert held.id in Screenshot.quarantined_ids()
      refute trusted.id in Screenshot.quarantined_ids()
      thumb = Screenshot.stored_thumb_path(%{trusted | screenshot: file})
      assert File.exists?(thumb)

      # No mosaic either: it stands in for a picture that is held.
      assert mosaic?(held, held_file)
      refute mosaic?(trusted, file)
    end

    test "a trusted profile link capture is released at once", %{tmp: tmp} do
      url = insert(:url, value: "https://www.tagesschau.de/story")

      PageScreenshot.capture_due(capture: fn _url -> {:ok, framed_capture(tmp), true} end)

      url = Repo.get!(Url, url.id)
      assert url.screenshot_moderation == "approved"
      refute scanned?("url_screenshot", url.id)
      assert_served(url)
    end

    test "an untrusted profile link capture still waits for the scan", %{tmp: tmp} do
      url = insert(:url, value: "https://blog.example/entry")

      PageScreenshot.capture_due(capture: fn _url -> {:ok, framed_capture(tmp), false} end)

      url = Repo.get!(Url, url.id)
      assert url.screenshot_moderation == "pending"
      assert scanned?("url_screenshot", url.id)
    end

    test "a trusted post link capture is released at once", %{tmp: tmp} do
      author = insert(:activated_user)
      post = create_post!(author, %{body: "https://www.tagesschau.de/story"})
      PostScreenshots.reconcile(post)

      PostScreenshots.deliver_due(force: true, capture: stored_capture(tmp, true))

      ps = Repo.one!(from(s in PostScreenshot, where: s.post_id == ^post.id))
      assert ps.moderation == "approved"
      assert PostScreenshot.ready?(ps)
      refute scanned?("post_screenshot", ps.id)
      assert_served(ps)
    end

    test "an untrusted post link capture still waits for the scan", %{tmp: tmp} do
      author = insert(:activated_user)
      post = create_post!(author, %{body: "https://blog.example/entry"})
      PostScreenshots.reconcile(post)

      PostScreenshots.deliver_due(force: true, capture: stored_capture(tmp, false))

      ps = Repo.one!(from(s in PostScreenshot, where: s.post_id == ^post.id))
      assert ps.moderation == "pending"
      assert scanned?("post_screenshot", ps.id)
    end

    test "a trusted organization homepage capture is released at once", %{tmp: tmp} do
      # Only a verified page gets a homepage capture; the DNS proof is stubbed.
      put_config(:verify_organization_domains, true)
      on_exit(fn -> Application.delete_env(:vutuv, :organizations_dns_resolver) end)
      {organization, _owner} = active_organization()

      OrganizationScreenshots.deliver_due(force: true, capture: stored_capture(tmp, true))

      capture = OrganizationScreenshots.for_organization(organization)
      assert capture.moderation == "approved"
      refute scanned?("organization_screenshot", capture.id)
      assert_served(capture)
    end
  end

  # A real, decodable image where the browser would have left its framed webp:
  # the store runs libvips over it, so a fake binary would test nothing.
  defp framed_capture(tmp) do
    path = Path.join(tmp, "framed-#{System.unique_integer([:positive])}.webp")
    {:ok, image} = Image.new(400, 264, color: [30, 90, 160])
    {:ok, _image} = Image.write(image, path)
    path
  end

  defp upload(tmp, scope),
    do: %Plug.Upload{
      content_type: "image/webp",
      filename: "#{scope.id}.webp",
      path: framed_capture(tmp)
    }

  defp mosaic?(scope, file) do
    Vutuv.Uploads.disk_dir("screenshots/#{scope.id}")
    |> Pixelation.path(Path.rootname(file))
    |> File.exists?()
  end

  # The post and organization queues' seam stubs the capture *and* its store,
  # so the stub stores for real, the way the real capture does; what the queue
  # itself decides is the row's moderation state and whether a scan is queued.
  defp stored_capture(tmp, trusted?) do
    fn job ->
      upload = %Plug.Upload{
        content_type: "image/webp",
        filename: "#{job.id}.webp",
        path: framed_capture(tmp)
      }

      {:ok, file} = Screenshot.store({upload, job}, trusted: trusted?)
      {:ok, %{screenshot: file, width: 400, height: 264, trusted: trusted?}}
    end
  end

  defp scanned?(kind, subject_id) do
    Repo.exists?(from(s in ImageScan, where: s.kind == ^kind and s.subject_id == ^subject_id))
  end

  defp assert_served(subject) do
    refute subject.id in Screenshot.quarantined_ids()
    assert File.exists?(Screenshot.stored_thumb_path(subject))
  end
end
