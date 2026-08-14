defmodule Vutuv.Moderation.StrandedQuarantineTest do
  @moduledoc """
  Issue #1443: a screenshot whose row left `pending` while its file stayed in
  the quarantine tree.

  `ImageSubjects.apply_approved/1` flips the row with `update_all` and calls
  `Screenshot.promote_from_quarantine/1` only afterwards, so anything ending
  the process in between (a deploy, a crash) — or an `update_all` that matches
  no row and answers `:stale` — leaves the subject approved with its bytes
  still in quarantine. The drift repair cannot see that state: it selects rows
  that are `pending`, and this one is not. On production it showed as a broken
  image on a public profile for ten hours, until a deploy's image regeneration
  rebuilt the thumb from the kept original by accident.

  Two defences are tested here. The serving side now **fails closed** (no file
  on disk means the placeholder, never a URL that 404s), which covers every
  cause including ones nobody has thought of; and the hourly drift repair now
  settles a stranded quarantine directory, which restores the picture instead
  of waiting for the next deploy.

  Not async: flips `:uploads_dir_prefix` (read by every uploader and every
  display helper) and `:moderate_images` (read by `Vutuv.Moderation.ImageScans`
  and, through it, by every upload path).
  """
  use VutuvWeb.ConnCase, async: false

  import Ecto.Query

  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo
  alias Vutuv.Screenshot

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_stranded_#{System.unique_integer([:positive])}")
    prev_dir = Application.fetch_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)
    Application.put_env(:vutuv, :moderate_images, true)

    on_exit(fn ->
      File.rm_rf(tmp)
      Application.put_env(:vutuv, :moderate_images, false)

      case prev_dir do
        {:ok, was} -> Application.put_env(:vutuv, :uploads_dir_prefix, was)
        :error -> Application.delete_env(:vutuv, :uploads_dir_prefix)
      end
    end)

    {:ok, tmp: tmp, user: insert_activated_user()}
  end

  defp capture_link(user) do
    src = Path.join(System.tmp_dir!(), "shot_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(300, 200, color: [10, 120, 200])
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)

    {:ok, url} =
      user
      |> Ecto.build_assoc(:urls)
      |> Url.changeset(%{"value" => "https://example.com"})
      |> Repo.insert()

    {:ok, url} =
      url
      |> Url.changeset(%{
        screenshot: %Plug.Upload{filename: "shot.jpg", path: src, content_type: "image/jpeg"}
      })
      |> Repo.update()

    url
  end

  # The production state: the scan cleared the image, the row says so, and the
  # file never left quarantine.
  defp strand(url) do
    {1, _} =
      Repo.update_all(from(u in Url, where: u.id == ^url.id),
        set: [screenshot_moderation: "approved"]
      )

    Repo.get!(Url, url.id)
  end

  defp quarantined?(tmp, url), do: Path.wildcard(quarantine_glob(tmp, url)) != []
  defp quarantine_glob(tmp, url), do: Path.join(tmp, "quarantine/screenshots/#{url.id}/*")
  defp served?(tmp, url), do: Path.wildcard(Path.join(tmp, "screenshots/#{url.id}/*")) != []

  describe "serving a screenshot whose file is not on disk" do
    test "answers the placeholder rather than a URL that 404s", %{tmp: tmp, user: user} do
      url = user |> capture_link() |> strand()

      # Calibration: the bytes really are only in quarantine, so the served
      # path this row names cannot resolve.
      assert quarantined?(tmp, url)
      refute served?(tmp, url)

      assert Screenshot.url({url.screenshot, url}, :thumb) == "/images/screenshot.png"
    end

    test "the links page calls such a tile pending, not a stored capture", %{
      conn: conn,
      user: user
    } do
      url = user |> capture_link() |> strand()

      html = conn |> get(~p"/#{user}/links") |> html_response(200)

      assert html =~ ~s|data-link-thumb="pending"|
      refute html =~ ~s|data-link-thumb="shot"|
      refute html =~ "/screenshots/#{url.id}/"
    end

    test "a screenshot that is really there still serves", %{tmp: tmp, user: user} do
      url = capture_link(user)
      # Release it the way an approved scan does.
      url = strand(url)
      Screenshot.promote_from_quarantine(url)

      assert served?(tmp, url)
      assert Screenshot.url({url.screenshot, url}, :thumb) =~ "/screenshots/#{url.id}/thumb-"
    end
  end

  describe "settle_stranded_quarantine/0" do
    test "promotes a stranded screenshot, so the picture comes back", %{tmp: tmp, user: user} do
      url = user |> capture_link() |> strand()

      assert ImageSubjects.settle_stranded_quarantine() == %{promoted: 1, dropped: 0}

      assert served?(tmp, url)
      refute quarantined?(tmp, url)
      assert Screenshot.url({url.screenshot, url}, :thumb) =~ "/screenshots/#{url.id}/thumb-"
    end

    test "leaves a subject that is still pending alone", %{tmp: tmp, user: user} do
      url = capture_link(user)
      assert url.screenshot_moderation == "pending"

      assert ImageSubjects.settle_stranded_quarantine() == %{promoted: 0, dropped: 0}

      # Publishing these bytes would be publishing an unreviewed image.
      assert quarantined?(tmp, url)
      refute served?(tmp, url)
    end

    test "drops bytes no row claims any more", %{tmp: tmp, user: user} do
      url = capture_link(user)
      Repo.delete_all(from(u in Url, where: u.id == ^url.id))

      assert ImageSubjects.settle_stranded_quarantine() == %{promoted: 0, dropped: 1}

      refute quarantined?(tmp, url)
      refute served?(tmp, url)
    end

    test "drops bytes the row has moved on from", %{tmp: tmp, user: user} do
      url = capture_link(user)

      {1, _} =
        Repo.update_all(from(u in Url, where: u.id == ^url.id),
          set: [screenshot: "0123456789ab.jpg", screenshot_moderation: "approved"]
        )

      assert ImageSubjects.settle_stranded_quarantine() == %{promoted: 0, dropped: 1}

      refute quarantined?(tmp, url)
      refute served?(tmp, url)
    end

    test "is idempotent and cheap when nothing is stranded" do
      assert ImageSubjects.settle_stranded_quarantine() == %{promoted: 0, dropped: 0}
      assert ImageSubjects.settle_stranded_quarantine() == %{promoted: 0, dropped: 0}
    end
  end
end
