defmodule Vutuv.Posts.PendingTest do
  @moduledoc """
  The post that waits for its media (issue #2106): the generalisation of the
  post that waited for its clip (#1910) to any set of media — a clip, files,
  the preview pages those files get (#2105) and the AI check on each page.

  `async: false`, because these tests flip `:vutuv, :attachments` and
  `:vutuv, :moderate_images`, which `Application.put_env/3` makes global state
  the SQL sandbox does not roll back.

  Two of these tests are about a **deploy** rather than about a post. The
  interrupt test kills the publisher mid-loop and asserts the sweeper finishes
  exactly the rest — no post twice, no notice twice; the clock test asserts a
  row the sweeper can do nothing for is out of the due query after one pass,
  instead of holding the front of every oldest-first batch for ever.
  """

  use Vutuv.DataCase

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  import Vutuv.AttachmentHelpers, only: [page!: 2, stalled_scan!: 2, stall_after_seconds: 0]

  alias Ecto.Adapters.SQL.Sandbox
  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Images.Image
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Posts
  alias Vutuv.Posts.Pending
  alias Vutuv.Posts.PendingPost
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostVideo
  alias Vutuv.Posts.Publisher
  alias Vutuv.Repo
  alias VutuvWeb.Live.PendingPostActions

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_pending_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "files"))
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{user: insert_activated_user(admin?: true), tmp: tmp, files: Path.join(tmp, "files")}
  end

  defp file!(user, files) do
    {:ok, attachment} = Attachments.create_pending(user, Fixtures.text_file(files), "notes.txt")
    attachment
  end

  defp rendered!(%Attachment{} = attachment) do
    Repo.update_all(from(a in Attachment, where: a.id == ^attachment.id),
      set: [stage: "ready", worked_at: nil]
    )

    %{attachment | stage: "ready"}
  end

  defp reload(%PendingPost{id: id}), do: Repo.get!(PendingPost, id)

  defp age!(%PendingPost{id: id}, seconds) do
    then = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds, :second)

    Repo.update_all(from(p in PendingPost, where: p.id == ^id),
      set: [updated_at: then, checked_at: DateTime.add(DateTime.utc_now(:second), -seconds)]
    )
  end

  describe "a post with files" do
    test "waits while the pages are rendered and publishes when the last one is checked",
         %{user: user, files: files} do
      Pending.subscribe(user.id)
      attachment = file!(user, files)

      {:ok, pending} =
        Pending.create(user, "post", %{}, %{body: "Read this"}, attachments: [attachment])

      assert pending.status == "waiting"
      assert Pending.in_progress_summary(user.id).count == 1
      assert Pending.state(pending) == :working

      # The render lands; the page still has to be checked.
      rendered!(attachment)
      page = page!(attachment, "pending")
      assert Pending.state(Pending.get(user, pending.id)) == :working
      assert Pending.sweep() >= 0
      assert reload(pending).status == "waiting"

      # The verdict lands, and that is the last thing the post waited for.
      Repo.update_all(from(i in Image, where: i.id == ^page.id), set: [moderation: "approved"])
      assert {:ok, post} = Pending.media_changed(:attachment, attachment.id)

      published = reload(pending)
      assert published.status == "published"
      assert published.post_id == post.id
      assert post.body == "Read this"
      assert Repo.get!(Attachment, attachment.id).post_id == post.id
      assert Repo.get!(Attachment, attachment.id).pending_post_id == nil

      post_id = post.id
      assert_received {:pending_post, %{status: "published", post_id: ^post_id}}
      assert Pending.in_progress_summary(user.id).count == 0
    end

    test "names every stage it is in", %{user: user, files: files} do
      Fixtures.put_config(preview_pages: 3)
      attachment = file!(user, files)

      {:ok, pending} =
        Pending.create(user, "post", %{}, %{body: "Stages"}, attachments: [attachment])

      assert Pending.stage(Pending.get(user, pending.id)) == {:rendering, 0, 1}

      page!(attachment, "pending")
      rendered!(attachment)
      assert Pending.stage(Pending.get(user, pending.id)) == {:checking, 1}
    end

    test "a refused file keeps the text and offers both ways out", %{user: user, files: files} do
      attachment = file!(user, files)

      {:ok, pending} =
        Pending.create(user, "post", %{}, %{body: "Text stays"}, attachments: [attachment])

      rendered!(attachment)
      Attachments.refuse(Repo.get!(Attachment, attachment.id))

      pending = Pending.get(user, pending.id)
      assert Pending.state(pending) == :refused
      assert reload(pending).status == "waiting"

      assert Pending.reading(pending).publishable_without_refused?

      assert {:ok, post} = Pending.publish_without_refused(pending)
      assert post.body == "Text stays"
      assert Repo.get(Attachment, attachment.id) == nil
    end

    test "a refused file that was the whole post offers only the way out that works",
         %{user: user, files: files} do
      attachment = file!(user, files)

      # No text and no photos: without the file there is no post to publish, and
      # the create path would refuse it — so that way out is not offered, and
      # the author is left with the one that works. Found in the browser: the
      # offer led to an opaque "could not be published" row.
      {:ok, pending} = Pending.create(user, "post", %{}, %{body: ""}, attachments: [attachment])

      rendered!(attachment)
      Attachments.refuse(Repo.get!(Attachment, attachment.id))

      pending = Pending.get(user, pending.id)
      assert Pending.state(pending) == :refused
      refute Pending.reading(pending).publishable_without_refused?

      assert {:error, _changeset} = Pending.publish_without_refused(pending)
    end

    test "cancelling drops the text and the files", %{user: user, files: files} do
      attachment = file!(user, files)

      {:ok, pending} =
        Pending.create(user, "post", %{}, %{body: "Never mind"}, attachments: [attachment])

      assert :ok = Pending.cancel(pending)
      assert reload(pending).status == "canceled"
      assert Repo.get(Attachment, attachment.id) == nil
    end

    test "a file a waiting post holds is neither swept nor re-adopted by a composer",
         %{user: user, files: files} do
      attachment = file!(user, files)
      {:ok, _} = Pending.create(user, "post", %{}, %{body: "wait"}, attachments: [attachment])

      old = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -48 * 3600, :second)
      Repo.update_all(from(a in Attachment), set: [inserted_at: old])

      assert Attachments.sweep_pending() == 0
      assert Repo.get(Attachment, attachment.id)
      assert Attachments.pending_for(user, [attachment.id]) == []
    end
  end

  describe "a post with photos alone" do
    test "publishes at once, with no pending row", %{user: user} do
      assert {:ok, %Post{}} = Posts.create_post(user, %{body: "Just words"})
      assert Pending.waiting_for(user) == []
    end
  end

  describe "the publisher survives a deploy" do
    test "a run killed mid-way is finished by the sweeper, publishing nothing twice",
         %{user: user, files: files} do
      Pending.subscribe(user.id)

      pendings =
        for n <- 1..3 do
          attachment = file!(user, files)

          {:ok, pending} =
            Pending.create(user, "post", %{}, %{body: "Post #{n}"}, attachments: [attachment])

          # Ready only now, and quietly: `create/5` publishes on the spot what
          # is already done, and the nudge from a real render is what these
          # three are standing in for having lost with their slot.
          rendered!(attachment)
          page!(attachment, "approved")
          pending
        end

      assert Enum.all?(pendings, &(reload(&1).status == "waiting"))
      assert length(Pending.due(10)) == 3

      parent = self()

      # A sweeper working its due list one row at a time and reporting each
      # one, so the kill lands at a moment this test names rather than one it
      # races for: a killed process is stopped between two rows here. A slot
      # killed **inside** a publish is the case below, which needs no timing at
      # all — and cannot be done with a kill, because a process killed inside
      # an open transaction takes the sandbox's shared connection down with it.
      {:ok, pid} =
        Task.start(fn ->
          receive do
            :go ->
              Enum.each(1..3, fn _ ->
                Pending.sweep(1)
                send(parent, :swept)
                Process.sleep(50)
              end)
          end
        end)

      Sandbox.allow(Repo, parent, pid)
      ref = Process.monitor(pid)
      send(pid, :go)

      assert_receive :swept, 5_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

      published_before = Repo.aggregate(Post, :count)
      assert published_before == 1, "the sweep did not stop where the kill left it"

      # Whatever the kill left mid-claim ages out; the sweeper finishes the rest.
      Enum.each(pendings, &age!(&1, Pending.stale_after_seconds() + 60))
      assert Pending.sweep(10) >= 3 - published_before

      assert Repo.aggregate(Post, :count) == 3,
             "the sweeper published a post a second time"

      for pending <- pendings do
        row = reload(pending)
        assert row.status == "published"
        assert Repo.get!(Post, row.post_id)
      end

      # One notice per post, never two.
      assert published_notices() == 3
    end

    test "a row whose post was already created is finished, not published again",
         %{user: user, files: files} do
      attachment = file!(user, files)

      {:ok, pending} =
        Pending.create(user, "post", %{}, %{body: "Once"}, attachments: [attachment])

      rendered!(attachment)
      page!(attachment, "approved")

      # What a slot killed between the insert and the bookkeeping leaves: the
      # row claimed, the post already there under the id the claim minted.
      assert {:ok, post} = Publisher.publish(reload(pending))

      Repo.update_all(from(p in PendingPost, where: p.id == ^pending.id),
        set: [status: "publishing", post_id: nil]
      )

      age!(pending, Pending.stale_after_seconds() + 60)

      assert Pending.sweep(10) == 1
      assert Repo.aggregate(Post, :count) == 1
      row = reload(pending)
      assert row.status == "published"
      assert row.post_id == post.id
    end

    test "a claim the PREVIOUS release made is never resumed, so nothing publishes twice",
         %{user: user, files: files} do
      attachment = file!(user, files)

      {:ok, pending} =
        Pending.create(user, "post", %{}, %{body: "Overlap"}, attachments: [attachment])

      rendered!(attachment)
      page!(attachment, "approved")

      # What the release this one replaces leaves behind, verbatim: its claim is
      # `SET status = 'publishing'` and nothing else — no `minted_post_id` (it
      # has no such column) and no `updated_at`, because `update_all` does not
      # bump timestamps. So the row is stale the instant it is claimed.
      Repo.update_all(from(p in PendingPost, where: p.id == ^pending.id),
        set: [status: "publishing", minted_post_id: nil]
      )

      # Its create path committed under an id of Ecto's own minting, and then
      # the deploy stopped the slot before the bookkeeping ran. Nothing on the
      # row names that post.
      {:ok, orphan} = Posts.create_in_context(user, "post", %{}, %{"body" => "Overlap"})
      age!(pending, Pending.stale_after_seconds() + 60)

      assert Pending.due(10) == [],
             "a claim with no minted id is resumable, and the resume cannot see the post that exists"

      assert Pending.sweep(10) == 0

      assert Repo.aggregate(Post, :count) == 1,
             "the member's post was published a second time during the deploy overlap"

      assert Repo.get!(Post, orphan.id)
      assert reload(pending).status == "publishing"
    end
  end

  describe "the sweeper's clock" do
    test "a row it can do nothing for leaves the due query after one pass",
         %{user: user, files: files} do
      attachment = file!(user, files)

      {:ok, pending} =
        Pending.create(user, "post", %{}, %{body: "Stuck"}, attachments: [attachment])

      # The file never finishes rendering: nothing about this row will change
      # in the next minute, so a pass that wrote no clock would hand it back
      # to every batch for ever.
      assert [%PendingPost{id: id}] = Pending.due(4)
      assert id == pending.id

      assert Pending.sweep(4) == 1
      assert reload(pending).status == "waiting"

      assert Pending.due(4) == [],
             "a row nothing can be done for is still at the front of the due query"
    end
  end

  describe "when the AI check cannot run" do
    test "past the ceiling the post stops claiming a check is in progress",
         %{user: user, files: files} do
      attachment = file!(user, files)

      {:ok, pending} =
        Pending.create(user, "post", %{}, %{body: "Read this"}, attachments: [attachment])

      rendered!(attachment)
      page = page!(attachment, "pending")

      # A blip is not a ceiling. Under it the check is merely late, the post is
      # work the server is doing, and the app bar says so.
      stalled_scan!(page, stall_after_seconds() - 60)
      assert Pending.stage(Pending.get(user, pending.id)) == {:checking, 1}
      assert Pending.in_progress_summary(user.id).count == 1

      # Past it the wait is unbounded, so the sentence changes and the row
      # stops counting as work in flight — it is waiting for its author now.
      stalled_scan!(page, stall_after_seconds() + 60)
      reading = Pending.reading(Pending.get(user, pending.id))
      assert reading.stage == :stalled
      assert reading.state == :stalled
      assert Pending.in_progress_summary(user.id).count == 0

      # The ceiling is the installation's to move, both ways.
      put_config(:ai_check_stall_seconds, 24 * 3_600)
      assert Pending.stage(Pending.get(user, pending.id)) == {:checking, 1}
    end

    test "a stalled row keeps its text, keeps its place in the queue and publishes itself " <>
           "when the scanner comes back",
         %{user: user, files: files} do
      attachment = file!(user, files)

      {:ok, pending} =
        Pending.create(user, "post", %{}, %{body: "Read this"}, attachments: [attachment])

      rendered!(attachment)
      page = page!(attachment, "pending")
      stalled_scan!(page, stall_after_seconds() + 3_600)
      assert Pending.reading(Pending.get(user, pending.id)).state == :stalled

      # Nothing was refused, so nothing offers to throw the file away, and the
      # sweeper leaves the row alone — but still advances its clock, or an
      # unworkable row would hold the front of every oldest-first batch.
      assert Pending.reading(Pending.get(user, pending.id)).publishable_without_refused? == false
      assert Pending.sweep(4) == 1
      assert reload(pending).status == "waiting"

      assert Pending.due(4) == [],
             "a row whose check cannot run is still at the front of the due query"

      # Ollama is back: the verdict lands and the post goes out by itself. An
      # outage of any length is a delay, never a refused post.
      Repo.update_all(from(i in Image, where: i.id == ^page.id), set: [moderation: "approved"])

      Repo.update_all(from(s in ImageScan, where: s.subject_id == ^page.id),
        set: [status: "approved", service_failing_since: nil]
      )

      assert {:ok, post} = Pending.media_changed(:attachment, attachment.id)
      assert reload(pending).status == "published"
      assert post.body == "Read this"
    end
  end

  describe "the author's page" do
    test "lists what waits and what was published", %{user: user, files: files} do
      attachment = file!(user, files)
      {:ok, done} = Pending.create(user, "post", %{}, %{body: "Done"}, attachments: [attachment])
      rendered!(attachment)
      page!(attachment, "approved")
      assert {:ok, _post} = Publisher.publish(reload(done))

      waiting_file = file!(user, files)

      {:ok, waiting} =
        Pending.create(user, "post", %{}, %{body: "Waiting"}, attachments: [waiting_file])

      assert [%PendingPost{id: id}] = Pending.waiting_for(user)
      assert id == waiting.id

      history = Pending.history_for(user)
      assert Enum.map(history, & &1.id) |> Enum.sort() == Enum.sort([done.id, waiting.id])
    end

    test "is the author's own queue: another member neither sees nor acts on the row",
         %{user: user, files: files} do
      attachment = file!(user, files)

      {:ok, pending} =
        Pending.create(user, "post", %{}, %{body: "Mine"}, attachments: [attachment])

      stranger = insert_activated_user()

      assert Pending.get(stranger, pending.id) == nil
      assert Pending.waiting_for(stranger) == []
      assert Pending.history_for(stranger) == []

      # The two ways out are keyed by the id the client sends, so the guard has
      # to be the query and not the card: a stranger pressing either on a row
      # of somebody else's changes nothing.
      for event <- PendingPostActions.events() do
        assert :ok = PendingPostActions.act(stranger, event, %{"id" => pending.id})
      end

      assert reload(pending).status == "waiting"
      assert Repo.aggregate(Post, :count) == 0
    end
  end

  describe "a post with a clip" do
    test "still waits on it, as one case of the same row", %{user: user} do
      video =
        Repo.insert!(%PostVideo{
          user_id: user.id,
          token: Vutuv.Uploads.gen_token(),
          stage: "transcoding",
          progress: 40
        })

      {:ok, pending} = Pending.create(user, "post", %{}, %{body: "Clip"}, video: video)
      assert Pending.state(pending) == :working
      assert match?({:video, %PostVideo{}}, Pending.stage(Pending.get(user, pending.id)))
    end
  end

  defp published_notices(seen \\ 0) do
    receive do
      {:pending_post, %{status: "published"}} -> published_notices(seen + 1)
    after
      0 -> seen
    end
  end
end
