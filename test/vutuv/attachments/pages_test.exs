defmodule Vutuv.Attachments.PagesTest do
  @moduledoc """
  The preview pages a file gets under a post (issue #2105): a PDF's first
  pages rendered by poppler, a text or Markdown file rendered by headless
  Chromium, each page a row of kind `attachment_page` on the shared `images`
  table so the AI scan applies to it as it does to a photo.

  `async: false`, and for the reason the rules file names: this module flips
  `:vutuv, :attachments` (read by the chokepoint, the composer and the
  sweeper) and `:vutuv, :chromium_path` (read by every screenshot pipeline),
  and `Application.put_env/3` is global state the SQL sandbox does not roll
  back.

  Two of these tests are about a deploy rather than about a picture. The
  **interrupt** test kills the rendering task mid-loop and asserts the sweeper
  finishes exactly the rest without re-rendering what already has its row; the
  **clock** test asserts that work nothing on this host can ever do leaves the
  due query after one pass, instead of holding the front of every batch for
  ever.
  """

  use Vutuv.DataCase

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.PageRender
  alias Vutuv.Attachments.Pages
  alias Vutuv.AttachmentStore
  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.MediaJobs.MediaJob
  alias Vutuv.Moderation
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.Repo

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_pages_#{System.unique_integer([:positive])}")
    files = Path.join(tmp, "files")
    File.mkdir_p!(files)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{user: insert_activated_user(admin?: true), tmp: tmp, files: files}
  end

  defp upload(user, path), do: Attachments.create_pending(user, path, Path.basename(path))

  defp stored!(user, path) do
    {:ok, attachment} = upload(user, path)
    attachment
  end

  # The claim heartbeat backdated past the staleness window — what a deploy
  # that stopped the slot mid-render leaves behind, minus the wait.
  defp age_claim!(%Attachment{id: id}) do
    stale =
      DateTime.add(DateTime.utc_now(:second), -(Pages.stale_after_seconds() + 60), :second)

    Repo.update_all(from(a in Attachment, where: a.id == ^id), set: [worked_at: stale])
  end

  defp reload(%Attachment{id: id}), do: Repo.get!(Attachment, id)

  describe "a PDF's first pages" do
    test "become image rows parented by the file", %{user: user, files: files} do
      Fixtures.put_config(preview_pages: 3)
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 5))

      assert %Attachment{stage: "ready"} = Pages.render(attachment)

      pages = Pages.list(attachment)
      assert length(pages) == 3
      assert Enum.map(pages, & &1.position) == [0, 1, 2]

      for page <- pages do
        assert %Image{kind: "attachment_page"} = page
        assert page.attachment_id == attachment.id
        assert page.user_id == user.id
        # The file has no post yet — the nullable pair is empty while the
        # composer holds it, and a page must never invent one.
        assert page.post_id == nil
        assert page.width > 0 and page.height > 0
        assert page.content_type == "image/avif"
        assert page.size_bytes > 0

        assert is_binary(
                 AttachmentStore.page_version_path(attachment.token, page.position, "large")
               )
      end
    end

    test "stop at five however many the installation asks for", %{user: user, files: files} do
      Fixtures.put_config(preview_pages: 9)
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 8))

      Pages.render(attachment)

      assert length(Pages.list(attachment)) == Pages.max_pages()
    end

    test "never exceed what the document has", %{user: user, files: files} do
      Fixtures.put_config(preview_pages: 3)
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 2))

      Pages.render(attachment)

      assert length(Pages.list(attachment)) == 2
    end

    test "are not rendered at all when the installation turned them off", %{
      user: user,
      files: files
    } do
      Fixtures.put_config(preview_pages: 0)
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 3))

      assert %Attachment{stage: "ready"} = Pages.render(attachment)
      assert Pages.list(attachment) == []
    end
  end

  describe "the AI image scan" do
    setup do
      # Off in the test environment by default; these four assertions are
      # exactly about the gate, so they turn it on for the module's lifetime
      # (which is why this file is sync — see the moduledoc).
      put_config(:moderate_images, true)
    end

    test "holds every page and can find its bytes", %{user: user, files: files} do
      Fixtures.put_config(preview_pages: 2)
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 4))

      Pages.render(attachment)

      for page <- Pages.list(attachment) do
        assert page.moderation == ImageScans.initial_state()

        assert %ImageScan{} =
                 scan = Repo.get_by(ImageScan, kind: "attachment_page", subject_id: page.id)

        assert scan.owner_user_id == user.id
        assert {:ok, bytes} = ImageSubjects.source(scan)
        assert File.exists?(bytes)
      end
    end

    test "releases a page it cleared", %{user: user, files: files} do
      Fixtures.put_config(preview_pages: 1)
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 1))
      Pages.render(attachment)

      [page] = Pages.list(attachment)
      scan = Repo.get_by!(ImageScan, kind: "attachment_page", subject_id: page.id)

      assert :ok = ImageSubjects.apply_approved(scan)
      assert Repo.get!(Image, page.id).moderation == "approved"
    end

    test "deletes a page it refused, bytes and row", %{user: user, files: files} do
      Fixtures.put_config(preview_pages: 1)
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 1))
      Pages.render(attachment)

      [page] = Pages.list(attachment)
      scan = Repo.get_by!(ImageScan, kind: "attachment_page", subject_id: page.id)

      assert :ok = ImageSubjects.apply_rejected(scan)
      assert Repo.get(Image, page.id) == nil
      assert AttachmentStore.page_version_path(attachment.token, 0, "large") == nil
      # The file itself is untouched: the scan judged the picture we derived.
      assert is_binary(AttachmentStore.served_path(attachment.token))
    end
  end

  describe "a killed render" do
    test "is finished by the sweeper, and nothing already rendered runs twice", %{
      user: user,
      files: files
    } do
      Fixtures.put_config(preview_pages: 5)
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 5))

      # The renderer waits for `:go` so its sandbox connection is granted before
      # it touches the database, and it is monitored so the kill below is
      # *observed* rather than assumed. An orphan still holding the connection
      # when the test ends is what makes this shape of test flake — the twin in
      # `Vutuv.VideosTest` fell over twice on 2026-09-10 with a
      # `DBConnection.Holder.checkout … no process` out of the sandbox.
      parent = self()

      {:ok, pid} =
        Task.start(fn ->
          receive do
            :go -> Pages.render(attachment)
          end
        end)

      Sandbox.allow(Repo, parent, pid)
      ref = Process.monitor(pid)
      send(pid, :go)

      wait_for(fn -> Pages.list(attachment) != [] end)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

      interrupted = Pages.list(attachment)
      assert length(interrupted) < 5, "the render finished before it could be interrupted"
      assert reload(attachment).stage == "rendering"

      # A marker in the bytes of every page that survived the kill. A re-render
      # writes each version over, so a marker that is still there afterwards is
      # proof the sweeper did not derive that page a second time — which no
      # assertion on the row could show, since the insert is idempotent either
      # way.
      marked =
        Map.new(interrupted, fn page ->
          path = AttachmentStore.page_version_path(attachment.token, page.position, "large")
          File.write!(path, "not a real avif, page #{page.position}")
          {page.position, {page.id, path}}
        end)

      # The slot is gone; only the stale heartbeat says so.
      age_claim!(attachment)
      assert [%Attachment{}] = Pages.due(4)

      assert Pages.sweep() == 1

      finished = Pages.list(attachment)
      assert length(finished) == 5
      assert reload(attachment).stage == "ready"

      by_position = Map.new(finished, &{&1.position, &1.id})

      for {position, {id, path}} <- marked do
        assert by_position[position] == id, "page #{position} got a second row"

        assert File.read!(path) == "not a real avif, page #{position}",
               "page #{position} was rendered a second time"
      end
    end
  end

  describe "the sweeper's clock" do
    test "drops work this host can never do out of the due query", %{user: user, files: files} do
      # poppler renders the pages, and this host has no such binary. `pdfinfo`
      # is a different one, so the file is still accepted.
      Fixtures.put_config(preview_pages: 3, pdftoppm: "vutuv-no-such-pdftoppm")
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 3))

      assert [%Attachment{}] = Pages.due(4)
      assert Pages.sweep() == 1

      # Aged past the staleness window first, which is the whole point: a pass
      # that merely claimed the file and wrote nothing looks finished for three
      # minutes and is then due again, for ever, at the front of every batch.
      age_claim!(attachment)
      assert Pages.due(4) == [], "a file nothing here can render is still due"

      assert reload(attachment).stage == "ready"
      assert Pages.list(attachment) == []

      assert %MediaJob{status: "done", detail: detail} = last_page_job()
      assert detail =~ "no renderer"
    end

    test "takes a strike when the renderer failed, and gives up after the cap", %{
      user: user,
      files: files
    } do
      # Present, and answers every run with a non-zero exit.
      Fixtures.put_config(preview_pages: 2, pdftoppm: System.find_executable("false"))
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 2))

      for attempt <- 1..Pages.max_attempts() do
        age_claim!(attachment)
        Pages.sweep()
        assert reload(attachment).render_attempts == attempt
      end

      assert reload(attachment).stage == "failed"
      assert Pages.due(4) == []
      assert %MediaJob{status: "failed"} = last_page_job()
    end
  end

  describe "the takedown a page does not have yet (#2109)" do
    # Written down because the absence is a *decision*, not an oversight, and
    # because every symptom of it is a quiet `nil` rather than an error: since
    # #2089 `Images.bytes_path/1` and `preview_url/1` answer `nil` for a kind
    # with no `@takedown` strategy instead of raising, so an admin surface
    # pointed at a page would read "no picture here" rather than "this kind is
    # not wired". `Vutuv.Moderation.reportable_by?/2`'s catch-all `%Image{}`
    # clause is the reason it must stay that way until #2109: it is
    # `takedown_ready?/1` and nothing else, so a kind put in the map becomes
    # reportable by anybody who can name a row id, with no visibility check, on
    # a page that may belong to a file no post has claimed. #2109 adds the
    # strategy and the visibility clause together; when it does, this test is
    # the one to invert.
    test "is refused everywhere rather than half-wired", %{user: user, files: files} do
      Fixtures.put_config(preview_pages: 1)
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 1))
      Pages.render(attachment)
      [page] = Pages.list(attachment)

      refute Images.takedown_ready?(page)
      assert Images.bytes_path(page) == nil
      assert Images.preview_url(page) == nil
      refute Moderation.can_report?(insert_activated_user(), page)
      refute Moderation.can_report?(user, page)

      # The bytes are there all the same — the `nil` above is the missing
      # strategy, not a missing picture.
      assert is_binary(Pages.bytes_path(page))
    end
  end

  describe "a text file" do
    test "degrades to no pages where there is no browser", %{user: user, files: files} do
      Fixtures.put_config(preview_pages: 3)
      put_config(:chromium_path, "/vutuv/no/such/chromium")
      attachment = stored!(user, Fixtures.markdown_file(files))

      assert %Attachment{stage: "ready"} = Pages.render(attachment)
      assert Pages.list(attachment) == []
      assert %MediaJob{status: "done", detail: detail} = last_page_job()
      assert detail =~ "no renderer"
    end
  end

  describe "the page a text file is drawn as" do
    # The capture is the one step a host without Chromium cannot run, and CI is
    # such a host — so what is asserted here is the document, which is where
    # every decision about a member's file actually sits.
    test "escapes plain text and forbids every outside reference" do
      attachment = %Attachment{content_type: "text/plain", file_name: "notes.txt"}

      html = PageRender.document(attachment, "1 < 2 & <script>alert(1)</script>")

      assert html =~ ~s(content="default-src 'none'; style-src 'unsafe-inline'")
      assert html =~ "1 &lt; 2 &amp; &lt;script&gt;"
      refute html =~ "<script>"
    end

    test "renders Markdown through our own renderer" do
      attachment = %Attachment{content_type: "text/markdown", file_name: "readme.md"}

      html = PageRender.document(attachment, "# Title\n\nA *word*.\n")

      assert html =~ "<h1>"
      assert html =~ "<em>word</em>"
      # A remote image is markup the renderer allows and the page must not
      # fetch. The CSP above is what stops the request; this hides the broken
      # frame it would otherwise leave in the middle of the preview.
      assert html =~ "img { display: none; }"
    end
  end

  describe "the media job" do
    test "records one rendering per file", %{user: user, files: files} do
      Fixtures.put_config(preview_pages: 2)
      attachment = stored!(user, Fixtures.multi_page_pdf(files, 3))

      Pages.render(attachment)

      assert %MediaJob{kind: "attachment_pages", status: "done"} = job = last_page_job()
      assert job.user_id == user.id
      assert job.subject_id == attachment.id
      assert job.detail =~ "2 pages"
    end
  end

  defp last_page_job do
    Repo.one(
      from(j in MediaJob, where: j.kind == "attachment_pages", order_by: [desc: j.id], limit: 1)
    )
  end

  # Polls rather than sleeps: the loop under test writes a row per page and
  # the test has to catch it between two of them.
  defp wait_for(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(5) && wait_for(fun, tries - 1)
    end
  end
end
