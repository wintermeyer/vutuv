defmodule Vutuv.Posts.LinkedFilePreviewTest do
  @moduledoc """
  A post whose one link answers with a file rather than a page: a picture is
  its own preview, a PDF previews with its first page, and anything else keeps
  the plain link. The whole queue runs for real here (probe, download, render,
  store); only the far side is a `plug:` stub.

  Not async: it flips `:post_screenshot_req_options` (read by the probe and
  the download in `Vutuv.Posts.Screenshots` and `Vutuv.Posts.LinkedFile`),
  `:uploads_dir_prefix` (every uploader), `:attachments` (every attachment
  path) and `:link_file_previews`.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_linked_file_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    put_config(:post_screenshot_req_options, [])
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  # Every request the queue makes (the probe, then the download) gets `body`
  # under `type`, and each one is counted so a test can tell a download from
  # none.
  defp serve(type, body) do
    test = self()

    put_config(:post_screenshot_req_options,
      plug: fn conn ->
        send(test, :requested)

        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.send_resp(200, body)
      end
    )
  end

  defp requests(count \\ 0) do
    receive do
      :requested -> requests(count + 1)
    after
      0 -> count
    end
  end

  defp run(url) do
    post = create_post!(insert(:activated_user), %{body: "Hier: #{url}"})
    {:ok, _job} = Screenshots.reconcile(post)
    Screenshots.deliver_due(force: true)
    Repo.get_by!(PostScreenshot, post_id: post.id)
  end

  defp png do
    {:ok, png} = Image.new!(64, 48, color: [200, 30, 30]) |> Image.write(:memory, suffix: ".png")
    png
  end

  test "a link to a picture previews with the picture itself" do
    serve("image/png", png())

    job = run("https://example.com/foto.png")

    assert job.status == "ready"
    assert is_binary(job.screenshot)
    # The probe, then the download: the probe's body is capped far below a
    # picture, so the preview cannot be cut from it.
    assert requests() == 2
  end

  test "a link to a PDF previews with its first page", %{tmp: tmp} do
    serve("application/pdf", File.read!(AttachmentFixtures.plain_pdf(tmp)))

    job = run("https://example.com/vortrag.pdf")

    assert job.status == "ready"
    assert is_binary(job.screenshot)
  end

  test "a file that is not what it claims to be keeps the plain link" do
    serve("application/pdf", "<html>no PDF here</html>")

    job = run("https://example.com/fake.pdf")

    assert job.status == "skipped"
    assert job.last_error =~ "not_a_pdf"
  end

  test "a picture above the attachment size limit is not downloaded whole" do
    put_config(
      :attachments,
      Keyword.put(Application.fetch_env!(:vutuv, :attachments), :max_filesize, 100)
    )

    serve("image/png", png())

    job = run("https://example.com/big.png")

    assert job.status == "skipped"
    assert job.last_error =~ "too_large"
  end

  test "an archive keeps the plain link and is never downloaded" do
    serve("application/zip", "PK\x03\x04")

    job = run("https://example.com/all.zip")

    assert job.status == "skipped"
    assert job.last_error =~ "not_a_page"
    assert requests() == 1
  end

  # The suite never runs Chromium (`config/test.exs`), which is exactly the
  # host that cannot draw a text file.
  test "a text file on a host without a browser keeps the plain link" do
    serve("text/plain", "Hallo Welt")

    job = run("https://example.com/liesmich.txt")

    assert job.status == "skipped"
    assert job.last_error =~ "no_renderer"
    assert requests() == 1
  end

  test "switched off, a file link is refused as before and never downloaded" do
    put_config(:link_file_previews, false)
    serve("image/png", png())

    job = run("https://example.com/foto.png")

    assert job.status == "skipped"
    assert job.last_error =~ "not_a_page"
    assert requests() == 1
  end
end
