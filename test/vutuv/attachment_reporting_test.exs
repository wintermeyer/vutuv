defmodule Vutuv.AttachmentReportingTest do
  @moduledoc """
  Reporting a file under a post (issue #2109): a file is a content type of its
  own in the moderation case machinery, a copyright notice moves it — and the
  preview pages that freeze with it — into `frozen/` rather than deleting
  anything, and an upheld case deletes the file and keeps the post.

  Two of these tests are about the hole #2105 left open on purpose. The kind
  `attachment_page` arrives in `Vutuv.Images`' `@takedown` registry here, and
  that registry is also what `Vutuv.Moderation.reportable_by?/2`'s catch-all
  `%Image{}` clause reads — so without the clause that lands beside it, any
  preview page would become reportable by whoever can name a row id, with no
  visibility check at all.

  The third is about a deploy. The hold root `frozen/` is swept by
  `Vutuv.Images.reconcile_holds/0`, which **deletes** every directory named by a
  UUID that has no `images` row behind it. A file's hold keyed by the
  attachment's own id would therefore be purged on the next sweeper pass and a
  rejected case could never put the file back.

  `async: false`: the freeze moves files on disk, and the module flips
  `:uploads_dir_prefix` and `:attachments`, which `Application.put_env/3` makes
  global state the SQL sandbox does not roll back.

  Every file here is rendered through `settle!/1` rather than a bare
  `Pages.render/1` (issue #2189). Half of what these tests say about a page is
  said *inside* a loop over `Pages.list/1`, so a render that produced nothing
  left the loop empty and the test green — and `stage: "ready"` does not rule
  that out, since the pipeline settles a file it has no renderer for at `ready`
  with no pages at all.
  """

  use Vutuv.DataCase, async: false

  import Vutuv.AttachmentHelpers, only: [settle!: 1]
  import Vutuv.OrganizationsHelpers, only: [active_organization: 0]
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.Pages
  alias Vutuv.AttachmentStore
  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.Moderation
  alias Vutuv.Moderation.Report
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Uploads

  @copyright %{
    "category" => "copyright",
    "note" => "Das ist mein Papier.",
    "good_faith?" => "true"
  }
  @house_rules %{"category" => "other", "note" => "Werbung."}

  setup do
    stamp = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "vutuv_report_files_#{stamp}")
    # Outside the uploads root on purpose: `tree/1` below reads every file under
    # it, and the source PDFs are not part of what a takedown moves.
    files = Path.join(System.tmp_dir!(), "vutuv_report_src_#{stamp}")
    File.mkdir_p!(tmp)
    File.mkdir_p!(files)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    on_exit(fn -> File.rm_rf(files) end)

    %{
      tmp: tmp,
      files: files,
      # `ATTACHMENT_UPLOADERS` is `admins` until a post can hand a file out.
      author: insert_activated_user(admin?: true),
      reporter: insert(:activated_user)
    }
  end

  # Every file under the uploads root, as `relative path => sha256` — the shape
  # `Vutuv.ModerationImageTakedownTest` compares a picture's round trip with.
  defp tree(root) do
    root
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Map.new(fn path ->
      {Path.relative_to(path, root), :crypto.hash(:sha256, File.read!(path))}
    end)
  end

  defp under(tree, prefix),
    do: tree |> Enum.filter(fn {path, _} -> String.starts_with?(path, prefix) end) |> Map.new()

  defp stored!(user, path) do
    {:ok, attachment} = Attachments.create_pending(user, path, Path.basename(path))
    attachment
  end

  # What publishing does (`Vutuv.Posts.Pending`): the post claims the file and
  # the reservation is cleared in the same statement.
  defp on_post!(%Attachment{id: id}, %Post{id: post_id}) do
    Repo.update_all(from(a in Attachment, where: a.id == ^id),
      set: [post_id: post_id, pending_post_id: nil]
    )

    Repo.get!(Attachment, id)
  end

  defp published_file(author, files, opts \\ []) do
    post = Keyword.get_lazy(opts, :post, fn -> insert(:post, user: author) end)

    files
    |> Fixtures.plain_pdf()
    |> then(&stored!(author, &1))
    |> on_post!(post)
  end

  defp reload(%Attachment{id: id}), do: Repo.get!(Attachment, id)

  describe "a file is a content type of its own" do
    test "reporting one opens an attachment case owned by the post's author", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      insert(:email, user: author)
      attachment = published_file(author, files)

      assert Moderation.content_type(attachment) == "attachment"
      assert {:ok, case_record} = Moderation.report_content(reporter, attachment, @house_rules)

      assert case_record.content_type == "attachment"
      assert case_record.content_id == attachment.id
      assert case_record.owner_id == author.id
      assert case_record.content_snapshot == attachment.file_name
      assert %Attachment{} = Moderation.case_content(case_record)
    end

    test "a file under a page's post answers to the member who claimed the page", %{
      author: author,
      files: files
    } do
      put_config(:verify_organization_domains, true)
      {organization, claimer} = active_organization()

      post = insert(:post, user: nil, organization: organization)
      attachment = published_file(author, files, post: post)

      # The uploader is not the accountable member: a page's content answers to
      # whoever claimed the page, not to whoever pressed publish.
      refute author.id == claimer.id
      assert Moderation.content_owner(attachment).id == claimer.id
    end

    test "a file the composer still holds is nobody's to report", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      attachment = stored!(author, Fixtures.plain_pdf(files))

      refute Moderation.can_report?(reporter, attachment)

      assert {:error, :not_allowed} =
               Moderation.report_content(reporter, attachment, @house_rules)
    end

    test "a file under a post the reporter cannot see is not reportable", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      post = insert(:post, user: author, frozen_at: NaiveDateTime.utc_now(:second))
      attachment = published_file(author, files, post: post)

      refute Moderation.can_report?(reporter, attachment)

      assert {:error, :not_allowed} =
               Moderation.report_content(reporter, attachment, @house_rules)
    end

    test "its own owner cannot report it", %{author: author, files: files} do
      attachment = published_file(author, files)
      assert {:error, :own_content} = Moderation.report_content(author, attachment, @house_rules)
    end
  end

  describe "the categories a file offers" do
    test "a file on a post offers the usual five", %{author: author, files: files} do
      attachment = published_file(author, files)
      assert Moderation.report_categories(attachment) == Report.categories()
    end

    test "a file in a private message has no copyright category", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      attachment = in_message!(author, reporter, files)
      refute Report.copyright_category() in Moderation.report_categories(attachment)
    end

    test "a category the type does not offer is refused", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      attachment = in_message!(author, reporter, files)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Moderation.report_content(reporter, attachment, @copyright)

      assert Keyword.has_key?(changeset.errors, :category)
    end
  end

  # A file on a private message: the other half of the nullable parent pair.
  # Nothing writes it yet (#2110), but the column is there and the answer for it
  # is not the post's — a message is not published, so there is nothing for a
  # rights holder to have taken down.
  defp in_message!(sender, other, files) do
    conversation = insert_conversation_between(sender, other)
    message = insert(:message, conversation: conversation, sender: sender)
    attachment = stored!(sender, Fixtures.plain_pdf(files))

    Repo.update_all(from(a in Attachment, where: a.id == ^attachment.id),
      set: [message_id: message.id]
    )

    Repo.get!(Attachment, attachment.id)
  end

  describe "the copyright freeze" do
    test "moves the file and its preview pages into frozen/, deleting nothing", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      insert(:email, user: author)
      attachment = author |> published_file(files) |> settle!()

      page_bytes =
        for page <- Pages.list(attachment), do: {page.id, File.read!(Pages.bytes_path(page))}

      served = AttachmentStore.served_path(attachment.token)
      file_bytes = File.read!(served)

      assert {:ok, case_record} = Moderation.report_content(reporter, attachment, @copyright)
      assert case_record.status == "pending_owner"

      frozen = reload(attachment)
      assert %NaiveDateTime{} = frozen.frozen_at

      # Nothing a reader can reach holds the file any more...
      refute File.exists?(served)
      refute AttachmentStore.served_path(attachment.token)

      # ...and every page row says so, which is what `Images.servable?/1` reads.
      for page <- Pages.list(attachment) do
        assert %NaiveDateTime{} = page.frozen_at
        refute Images.servable?(page)
      end

      # ...but every byte is still there, in the hold.
      assert File.read!(Attachments.held_file_path(frozen)) == file_bytes

      for {page_id, bytes} <- page_bytes do
        page = Repo.get!(Image, page_id)
        assert File.read!(Images.bytes_path(page)) == bytes
      end
    end

    # The claim above, made over the **whole tree** rather than over the three
    # paths this test happens to name: a file's served directory holds the file,
    # its private original one tree over, and a `pages/<n>/` subdirectory per
    # rendered page holding four derived sizes. `Vutuv.Uploads.move_all/2` moves
    # files and skips directories, so a page left standing is exactly the shape
    # this has to be able to see.
    test "the whole tree moves, and a rejected case brings it back byte for byte", %{
      tmp: tmp,
      author: author,
      reporter: reporter,
      files: files
    } do
      insert(:email, user: author)
      admin = insert_activated_user(admin?: true)
      attachment = author |> published_file(files) |> settle!()

      before = tree(tmp)
      # The served copy, the private original, and the page's derived sizes in
      # a subdirectory of the first — named, because "the same number of files
      # came back" is not what this test is for.
      assert under(before, "attachments/#{attachment.token}/pages/") != %{}
      assert under(before, "originals/attachments/#{attachment.token}/") != %{}
      assert under(before, "frozen/") == %{}

      {:ok, case_record} = Moderation.report_content(reporter, attachment, @copyright)

      held = tree(tmp)
      # Not one byte is left anywhere a reader could reach...
      assert under(held, "attachments/") == %{}
      assert under(held, "originals/") == %{}
      # ...they are all in the hold, contents unchanged, however the paths moved.
      assert map_size(under(held, "frozen/")) == map_size(before)

      assert held |> under("frozen/") |> Map.values() |> Enum.sort() ==
               before |> Map.values() |> Enum.sort()

      {:ok, _} = Moderation.reject_case(case_record, admin)

      assert tree(tmp) == before
      assert reload(attachment).frozen_at == nil
      for page <- Pages.list(attachment), do: assert(page.frozen_at == nil)
    end

    test "a house-rule report leaves the file where it is", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      attachment = published_file(author, files)

      assert {:ok, case_record} = Moderation.report_content(reporter, attachment, @house_rules)
      assert case_record.status == "flagged"
      assert reload(attachment).frozen_at == nil
      assert AttachmentStore.served_path(attachment.token)
    end
  end

  describe "the two ways a file goes for good" do
    test "upholding deletes the file and keeps the post", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      insert(:email, user: author)
      admin = insert_activated_user(admin?: true)
      post = insert(:post, user: author)
      attachment = author |> published_file(files, post: post) |> settle!()

      {:ok, case_record} = Moderation.report_content(reporter, attachment, @copyright)

      assert Moderation.uphold_content_effect(case_record, reload(attachment)) == :deleted

      {:ok, upheld} = Moderation.uphold_case(case_record, admin)
      assert upheld.status == "upheld"

      refute Repo.get(Attachment, attachment.id)
      assert Pages.list(attachment) == []
      refute File.exists?(Uploads.disk_dir("attachments/#{attachment.token}"))
      # The post is not what the claim was about.
      assert Repo.get(Post, post.id)
    end

    test "the owner's own 'remove it' does the same without an admin", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      insert(:email, user: author)
      post = insert(:post, user: author)
      attachment = published_file(author, files, post: post)

      {:ok, case_record} = Moderation.report_content(reporter, attachment, @copyright)
      case_record = Moderation.get_case_with_details(case_record.id)

      assert :ok = Moderation.delete_reported_content(case_record, author)

      refute Repo.get(Attachment, attachment.id)
      assert Repo.get(Post, post.id)
      assert Moderation.get_case(case_record.id).status == "resolved_deleted"
    end
  end

  describe "a preview page is not separately reportable" do
    test "although its kind now has a takedown", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      attachment = author |> published_file(files) |> settle!()
      [page] = Pages.list(attachment)

      # The strategy registry is what makes the freeze work at all...
      assert Images.takedown_ready?(page)

      # ...and it is also what the catch-all `%Image{}` report gate reads, so
      # without a clause of its own a page would be reportable by anybody who
      # can name a row id, on a file no post has claimed.
      refute Moderation.can_report?(reporter, page)
      assert {:error, :not_allowed} = Moderation.report_content(reporter, page, @house_rules)
    end
  end

  describe "a freeze that a deploy interrupted" do
    test "is finished by the sweeper, and the image sweep does not eat its hold", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      insert(:email, user: author)
      attachment = author |> published_file(files) |> settle!()

      {:ok, _case_record} = Moderation.report_content(reporter, attachment, @copyright)
      frozen = reload(attachment)
      held = Attachments.held_file_path(frozen)
      assert File.exists?(held)

      # The pass that would delete a hold keyed by a row it does not know.
      Images.reconcile_holds()
      Attachments.reconcile_holds()

      still_held = Attachments.held_file_path(reload(attachment))

      assert is_binary(still_held),
             "the image hold sweep ate the file's hold, so a rejected case could never put it back"

      assert File.exists?(still_held)

      for page <- Pages.list(attachment) do
        assert %NaiveDateTime{} = page.frozen_at
        assert File.exists?(Images.bytes_path(page))
      end
    end

    test "a half-done move is re-asserted from the row", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      insert(:email, user: author)
      attachment = published_file(author, files)

      {:ok, _} = Moderation.report_content(reporter, attachment, @copyright)
      frozen = reload(attachment)

      # What a slot killed between the two renames leaves behind: the stamp is
      # on the row and a file is back in the tree a reader can reach.
      held = Attachments.held_file_path(frozen)
      back = Path.join(Uploads.disk_dir("attachments/#{attachment.token}"), Path.basename(held))
      File.mkdir_p!(Path.dirname(back))
      File.rename!(held, back)

      Attachments.reconcile_holds()

      refute File.exists?(back)
      assert File.exists?(Attachments.held_file_path(reload(attachment)))
    end

    # The other direction, and the one an interrupted *release* leaves: a slot
    # that died between the `frozen_at: nil` write and the move leaves the bytes
    # in a hold behind a row that is no longer frozen, and nothing about the row
    # says so.
    test "a release that never finished is finished too", %{
      author: author,
      reporter: reporter,
      files: files
    } do
      insert(:email, user: author)
      attachment = published_file(author, files)

      {:ok, _} = Moderation.report_content(reporter, attachment, @copyright)

      Repo.update_all(from(a in Attachment, where: a.id == ^attachment.id),
        set: [frozen_at: nil]
      )

      assert is_binary(Attachments.held_file_path(attachment))

      Attachments.reconcile_holds()

      assert AttachmentStore.served_path(attachment.token)
      refute Attachments.held_file_path(attachment)
    end

    # And the third: an upheld case that died between the purge and the hold.
    test "a hold whose row is gone is deleted", %{author: author, files: files} do
      attachment = published_file(author, files)
      :ok = Attachments.freeze(attachment)
      assert is_binary(Attachments.held_file_path(attachment))

      Repo.delete_all(from(a in Attachment, where: a.id == ^attachment.id))
      Attachments.reconcile_holds()

      refute Attachments.held_file_path(attachment)
    end
  end
end
