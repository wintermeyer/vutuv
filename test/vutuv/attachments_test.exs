defmodule Vutuv.AttachmentsTest do
  @moduledoc """
  The upload chokepoint for files on posts (issue #2104): who may upload, what
  the caps refuse, what the PDF gate refuses, and the budget that counts
  accepted uploads rather than stored bytes.

  The PDFs are real and built at run time (`Vutuv.AttachmentFixtures`), and
  `pdfinfo` really runs, so what is asserted here is what a member gets. Each
  hostile PDF is tried twice: as written, and with every dictionary moved into
  a compressed object stream — the transformation that empties a raw-byte scan
  while the document goes on doing the same thing.
  """

  use Vutuv.DataCase

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.AttachmentStore
  alias Vutuv.MediaJobs.MediaJob
  alias Vutuv.Repo

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_attachments_#{System.unique_integer([:positive])}")
    files = Path.join(tmp, "files")
    File.mkdir_p!(files)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    # Uploads are for admins until an installation opens them, exactly like
    # video; the budget block below opens them and uses plain members, since
    # an admin has no budget to hit.
    %{user: insert_activated_user(admin?: true), tmp: tmp, files: files}
  end

  defp upload(user, path), do: Attachments.create_pending(user, path, Path.basename(path))

  describe "who may upload" do
    test "a plain member is refused while uploads are for admins", %{files: files} do
      member = insert_activated_user()
      assert {:error, :disabled} = upload(member, Fixtures.plain_pdf(files))
    end

    test "with the installation switched off nobody may", %{user: user, files: files} do
      Fixtures.put_config(enabled: false)

      assert {:error, :disabled} = upload(user, Fixtures.plain_pdf(files))
    end
  end

  describe "what is accepted" do
    test "a PDF is stored with its page count", %{user: user, files: files} do
      assert {:ok, %Attachment{} = attachment} = upload(user, Fixtures.plain_pdf(files))
      assert attachment.content_type == "application/pdf"
      assert attachment.page_count == 1
      assert attachment.post_id == nil and attachment.message_id == nil
      assert attachment.size_bytes > 0
    end

    test "a text file and a Markdown file keep their own content types", %{
      user: user,
      files: files
    } do
      assert {:ok, text} = upload(user, Fixtures.text_file(files))
      assert text.content_type == "text/plain"
      assert text.page_count == nil

      assert {:ok, markdown} = upload(user, Fixtures.markdown_file(files))
      assert markdown.content_type == "text/markdown"
    end

    test "the original is kept verbatim and the served copy is written", %{
      user: user,
      files: files
    } do
      source = Fixtures.plain_pdf(files)
      assert {:ok, attachment} = upload(user, source)

      original = AttachmentStore.original_path(attachment.token)
      assert File.read!(original) == File.read!(source)
      assert File.exists?(AttachmentStore.served_path(attachment.token))
    end

    test "an OpenAction that is only a destination is fine", %{user: user, files: files} do
      assert {:ok, _attachment} = upload(user, Fixtures.destination_pdf(files))
    end

    test "the intake writes a media job", %{user: user, files: files} do
      assert {:ok, _attachment} = upload(user, Fixtures.plain_pdf(files))

      assert [%MediaJob{kind: "attachment_intake", status: "done"}] =
               Repo.all(MediaJob)
    end

    test "a refusal is a finished media job, not a failed one", %{user: user, files: files} do
      assert {:error, :javascript} = upload(user, Fixtures.javascript_pdf(files))

      assert [%MediaJob{kind: "attachment_intake", status: "done", detail: detail}] =
               Repo.all(MediaJob)

      assert detail =~ "javascript"
    end
  end

  describe "the size cap" do
    test "one byte over is refused", %{user: user, files: files} do
      Fixtures.put_config(max_filesize: 1_000)

      assert {:error, :too_large} = upload(user, Fixtures.sized_file(files, 1_001))
      assert {:ok, _} = upload(user, Fixtures.sized_file(files, 1_000, "exact.txt"))
    end

    test "an over-cap file is never stored", %{user: user, files: files, tmp: tmp} do
      Fixtures.put_config(max_filesize: 1_000)

      assert {:error, :too_large} = upload(user, Fixtures.sized_file(files, 5_000))
      assert Path.wildcard(Path.join(tmp, "attachments/**/*")) == []
    end
  end

  describe "the format is read from the bytes" do
    test "a ZIP under a .pdf name is refused", %{user: user, files: files} do
      assert {:error, :invalid_file} = upload(user, Fixtures.zip_named_pdf(files))
    end

    test "a PDF under a .txt name is refused", %{user: user, files: files} do
      pdf = Fixtures.plain_pdf(files)
      renamed = Path.join(files, "notes.txt")
      File.cp!(pdf, renamed)

      assert {:error, :invalid_file} = upload(user, renamed)
    end

    test "an extension nobody offered is refused", %{user: user, files: files} do
      path = Path.join(files, "script.sh")
      File.write!(path, "echo hi\n")

      assert {:error, :invalid_file} = upload(user, path)
    end

    test "a text file with NUL bytes in it is not text", %{user: user, files: files} do
      path = Path.join(files, "binary.txt")
      File.write!(path, "hello" <> <<0, 1, 2>> <> "world")

      assert {:error, :invalid_file} = upload(user, path)
    end
  end

  describe "the PDF gate" do
    test "an encrypted PDF is refused", %{user: user, files: files} do
      assert {:error, :encrypted} = upload(user, Fixtures.encrypted_pdf(files))
    end

    test "a PDF with an owner password is refused too", %{user: user, files: files} do
      assert {:error, :encrypted} = upload(user, Fixtures.owner_encrypted_pdf(files))
    end

    test "a PDF with JavaScript is refused", %{user: user, files: files} do
      assert {:error, :javascript} = upload(user, Fixtures.javascript_pdf(files))
    end

    test "a PDF that acts when it is opened is refused", %{user: user, files: files} do
      assert {:error, :open_action} = upload(user, Fixtures.open_action_pdf(files))
    end

    test "a PDF carrying another file is refused", %{user: user, files: files} do
      assert {:error, :embedded_files} = upload(user, Fixtures.embedded_file_pdf(files))
    end

    # The `/OpenAction` rule reads what follows the name and lets a destination
    # through, so an action that is not spelled `/OpenAction <<action>>` walked
    # past it: `pdfinfo` answers `JavaScript: no` for both of these and the gate
    # accepted them until the acting names were added. Calibration: take
    # `@acting_names` back out of `Vutuv.Uploads.PdfGate` and both go red with
    # `{:ok, _}`. Cost measured over 1,051 real local PDFs: `/Launch`,
    # `/SubmitForm` and `/ImportData` in none of them.
    test "an OpenAction that chains a launch behind /Next is refused", %{
      user: user,
      files: files
    } do
      assert {:error, :open_action} = upload(user, Fixtures.chained_launch_pdf(files))
    end

    test "a page whose /AA launches something is refused", %{user: user, files: files} do
      assert {:error, :open_action} = upload(user, Fixtures.page_action_launch_pdf(files))
    end

    test "hiding the trick in an object stream does not get it past", %{user: user, files: files} do
      # `qpdf --object-streams=generate` compresses every dictionary away, so
      # a raw-byte grep for these three names comes back empty. Each is
      # asserted by name: without the inflation pass in `PdfGate` the
      # `/OpenAction` line is the one that goes red, because poppler answers
      # the other two for itself.
      got =
        for {source, reason} <- [
              {Fixtures.javascript_pdf(files), :javascript},
              {Fixtures.open_action_pdf(files), :open_action},
              {Fixtures.embedded_file_pdf(files), :embedded_files}
            ],
            hidden = Fixtures.hidden(files, source),
            hidden != nil do
          case upload(user, hidden) do
            {:error, seen} -> {reason, seen}
            {:ok, _accepted} -> {reason, :accepted}
          end
        end

      assert Enum.all?(got, fn {reason, seen} -> reason == seen end),
             "hidden in an object stream, the gate answered: #{inspect(got)}"
    end

    test "a refused PDF leaves nothing on disk", %{user: user, files: files, tmp: tmp} do
      assert {:error, :javascript} = upload(user, Fixtures.javascript_pdf(files))
      assert Path.wildcard(Path.join(tmp, "attachments/**/*")) == []
      assert Path.wildcard(Path.join(tmp, "originals/attachments/**/*")) == []
    end

    test "without poppler a PDF is refused and text still works", %{user: user, files: files} do
      Fixtures.put_config(pdfinfo: "vutuv-no-such-binary")

      Attachments.forget_capability()
      on_exit(&Attachments.forget_capability/0)

      refute Attachments.pdf_supported?()
      assert {:error, :pdf_unavailable} = upload(user, Fixtures.plain_pdf(files))
      assert {:ok, _text} = upload(user, Fixtures.text_file(files))
    end
  end

  describe "the budget" do
    setup do
      Fixtures.put_config(uploaders: :members, daily_budget: 3_000, monthly_budget: 5_000)

      %{member: insert_activated_user()}
    end

    test "a member at their daily budget is refused", %{member: member, files: files} do
      assert {:ok, _} = upload(member, Fixtures.sized_file(files, 2_000, "a.txt"))
      assert {:error, :daily_budget} = upload(member, Fixtures.sized_file(files, 1_500, "b.txt"))
    end

    test "a member at their monthly budget is refused", %{member: member, files: files} do
      # Yesterday's uploads are outside the daily window but inside the monthly one.
      Attachments.record_upload!(member, 4_500, hours_ago: 30)

      assert {:error, :monthly_budget} =
               upload(member, Fixtures.sized_file(files, 1_000, "c.txt"))
    end

    test "deleting the file does not give the bytes back", %{member: member, files: files} do
      assert {:ok, attachment} = upload(member, Fixtures.sized_file(files, 2_000, "d.txt"))
      before = Attachments.budget_for(member)

      :ok = Attachments.delete_pending(attachment)

      assert Attachments.budget_for(member).daily.used == before.daily.used
      assert {:error, :daily_budget} = upload(member, Fixtures.sized_file(files, 1_500, "e.txt"))
    end

    test "a refused upload costs nothing", %{member: member, files: files} do
      assert {:error, :javascript} = upload(member, Fixtures.javascript_pdf(files))
      assert Attachments.budget_for(member).daily.used == 0
    end

    test "an admin has no budget", %{user: user, files: files} do
      budget = Attachments.budget_for(user)
      assert budget.unlimited?
      assert budget.daily == nil and budget.monthly == nil

      assert {:ok, _} = upload(user, Fixtures.sized_file(files, 4_000, "f.txt"))
      assert {:ok, _} = upload(user, Fixtures.sized_file(files, 4_000, "g.txt"))
    end
  end

  describe "the abandoned-composer sweep" do
    test "a file nobody attached is taken with its bytes", %{user: user, files: files} do
      assert {:ok, attachment} = upload(user, Fixtures.plain_pdf(files))
      dir = Path.dirname(AttachmentStore.served_path(attachment.token))

      assert Attachments.sweep_pending(0) == 1
      refute Repo.get(Attachment, attachment.id)
      refute File.exists?(dir)
      refute File.exists?(AttachmentStore.original_path(attachment.token) || "/nonexistent")
    end

    test "a file that belongs to a post stays", %{user: user, files: files} do
      assert {:ok, attachment} = upload(user, Fixtures.plain_pdf(files))
      {:ok, post} = Vutuv.Posts.create_post(user, %{body: "text"})

      attachment |> Ecto.Changeset.change(post_id: post.id) |> Repo.update!()

      assert Attachments.sweep_pending(0) == 0
      assert Repo.get(Attachment, attachment.id)
    end

    test "a file that belongs to a message stays", %{user: user, files: files} do
      assert {:ok, attachment} = upload(user, Fixtures.plain_pdf(files))
      other = insert_activated_user()
      {:ok, conversation} = Vutuv.Chat.find_or_create_conversation(user, other)
      message = Vutuv.ChatHelpers.send!(user, conversation)

      attachment |> Ecto.Changeset.change(message_id: message.id) |> Repo.update!()

      assert Attachments.sweep_pending(0) == 0
      assert Repo.get(Attachment, attachment.id)
    end
  end
end
