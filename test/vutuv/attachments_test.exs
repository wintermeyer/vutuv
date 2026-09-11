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
  alias Vutuv.WorkCounter

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

    # Issue #2136. This CV's page says "HTML/CSS/JavaScript", its title says it
    # again and a link annotation points at MDN's `/docs/Web/JavaScript`, and
    # none of that is an action — `pdfinfo` answers `JavaScript: no`. Every one
    # of those words is inside a PDF **string**, which is what the gate now
    # blanks before it looks for a name. Calibration: stop `scan_buffer/1` in
    # `Vutuv.Uploads.PdfGate` from calling `without_content/1` and both halves
    # go red with `{:error, :embedded_files}`, on the sentence about print PDFs.
    test "a CV that lists web skills is not a program", %{user: user, files: files} do
      assert {:ok, _compressed} = upload(user, Fixtures.web_skills_cv_pdf(files))

      assert {:ok, _uncompressed} =
               upload(user, Fixtures.web_skills_cv_pdf(files, compress: false))
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
    # The encrypted fixtures are built with qpdf, which the gate itself does not
    # use (poppler answers encryption) — CI carries poppler but not qpdf, so
    # `nil` means "cannot build the fixture here" and the check is left to a dev
    # machine with qpdf, the same skip `hidden/2` already takes.
    test "an encrypted PDF is refused", %{user: user, files: files} do
      case Fixtures.encrypted_pdf(files) do
        nil -> :ok
        path -> assert {:error, :encrypted} = upload(user, path)
      end
    end

    test "a PDF with an owner password is refused too", %{user: user, files: files} do
      case Fixtures.owner_encrypted_pdf(files) do
        nil -> :ok
        path -> assert {:error, :encrypted} = upload(user, path)
      end
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

    # Seven places a script can hang, two of which `pdfinfo` does not report at
    # all — a `/Next` chain behind a destination, as a dictionary or as an array
    # — and one it reports only on some builds. What answers for those is
    # `/JavaScript` in `@name_regexes`, which is why it is there beside poppler
    # rather than instead of it (#2136). Calibration: take `"JavaScript"` back
    # out of `@name_regexes` and the two `/Next` lines go red with `{:ok, _}`.
    #
    # Note which way that calibration does *not* run: disabling poppler's
    # `JavaScript:` answer leaves all seven green, because every one of these
    # fixtures also carries the name in bytes this can read. What poppler alone
    # answers is the object-stream variant below, and only where qpdf can build
    # the fixture.
    test "JavaScript is refused wherever the action hangs", %{user: user, files: files} do
      wheres = [
        :open_action,
        :catalog_aa,
        :page_aa,
        :annotation,
        :next_dict,
        :next_array,
        :field_calculate
      ]

      got =
        for where <- wheres do
          {where, upload(user, Fixtures.action_javascript_pdf(files, where))}
        end

      assert Enum.all?(got, &match?({_where, {:error, :javascript}}, &1)),
             "the gate answered: #{inspect(got)}"
    end

    # Bare `pdfinfo` reads page 1 and stops, so a one-page fixture proves
    # nothing about a two-page CV. Calibration: drop `-f 1 -l 999999` from
    # `pdfinfo/1` and all three go red — with `{:ok, _}` if `"JavaScript"` is
    # also out of `@name_regexes`, which is the pair of changes that let five
    # such files through on 2026-09-11.
    test "a script on a page nobody looks at is still a script", %{user: user, files: files} do
      got =
        for {pages, on} <- [{3, 2}, {3, 3}, {20, 20}] do
          {{pages, on}, upload(user, Fixtures.page_javascript_pdf(files, pages, on))}
        end

      assert Enum.all?(got, &match?({_where, {:error, :javascript}}, &1)),
             "the gate answered: #{inspect(got)}"
    end

    # `pdfinfo` exiting 0 with nothing to say is not a clean bill: a
    # positive-match test reads that silence as "no JavaScript here". `true(1)`
    # is the cheapest poppler that lies. Calibration: accept any exit-0 output
    # in `pdfinfo/1` and this goes red with `{:ok, _}` — the gate storing a file
    # it never checked.
    test "a poppler that answers nothing has not answered", %{user: user, files: files} do
      Fixtures.put_config(pdfinfo: "/usr/bin/true")
      Attachments.forget_capability()
      on_exit(&Attachments.forget_capability/0)

      assert {:error, :unreadable} = upload(user, Fixtures.plain_pdf(files))
    end

    # `/EmbeddedFile` is the other half of that decision and went the other way:
    # poppler counts a file on a `/FileAttachment` annotation even when nothing
    # names it as one, so the first two of these are its answer — and answers
    # **0** for one reached through the catalog's `/AF`, so the third is the
    # byte scan's. Calibration: take `"EmbeddedFile"` out of `@name_regexes` in
    # `Vutuv.Uploads.PdfGate` and the `/AF` line alone goes red with `{:ok, _}`.
    test "a file carried inside is refused however it is hung", %{user: user, files: files} do
      assert {:error, :embedded_files} = upload(user, Fixtures.file_attachment_pdf(files))

      assert {:error, :embedded_files} =
               upload(user, Fixtures.file_attachment_pdf(files, typed: false))

      assert {:error, :embedded_files} = upload(user, Fixtures.associated_file_pdf(files))
    end

    # A blanking pass reads a buffer front to back; a reader picks each object
    # out of an object stream at the offset its table records. Where those two
    # part company, a `(` in one object and a `)` in another would blank the
    # catalog between them — so a candidate string holding a `<<` is not
    # blanked. Calibration: let `blank_unless_dictionary/4` in
    # `Vutuv.Uploads.PdfGate` exempt every range and this goes red with
    # `{:ok, _}`.
    test "a launch wrapped in brackets is still a launch", %{user: user, files: files} do
      assert {:error, :open_action} = upload(user, Fixtures.string_wrapped_launch_pdf(files))
    end

    # The three below are not calibrated against #2136 — the narrowing does not
    # touch them, and they pass with and without it. They are here because the
    # narrowing had to be shown to lose nothing, and each names a different
    # layer: the `#XX` alternation in `@name_regexes`, the raw-file half of the
    # scan (an incremental update leaves the first revision's bytes alone), and
    # `pdfinfo` itself on a file no parser can open.
    test "a launch spelled with hex escapes is refused", %{user: user, files: files} do
      assert {:error, :open_action} = upload(user, Fixtures.hex_escaped_launch_pdf(files))
    end

    test "a second revision that appends a launch is refused", %{user: user, files: files} do
      assert {:error, :open_action} = upload(user, Fixtures.incremental_launch_pdf(files))
    end

    test "a PDF header with nothing readable behind it is refused", %{user: user, files: files} do
      assert {:error, :unreadable} = upload(user, Fixtures.header_then_garbage_pdf(files))
    end

    # `@stream_limit` without qpdf: the fixture below needs no external tool, so
    # this is the one that still runs on CI.
    test "a stream that inflates to 20 MB is refused", %{user: user, files: files} do
      assert {:error, :unreadable} = upload(user, Fixtures.decompression_bomb_pdf(files))
    end

    # The blanking pass reads the file, so a file can make it work. Reductions
    # rather than a clock, because the suite runs twenty cases at once (see
    # `Vutuv.WorkCounter`). Calibrated both ways on 2026-09-11: as it stands,
    # 47,915 reductions for 30 KB and 64,525 for 60 KB, the difference being
    # mostly the upload around it. Make `blank_unless_dictionary/5` in
    # `Vutuv.Uploads.PdfGate` resume at `at + 1` again and the same two are
    # **90 million** and **321 million**, quadrupling with every doubling: 2.8
    # seconds of a LiveView's own process for a 60 KB file, and days for one at
    # the 20 MB cap.
    # A lone `<` at the end of the file leaves the hex-string branch nothing to
    # reach into, so a resume computed from that reach lands back on the same
    # byte. Calibration: resume at `at + reach` again and this goes red with
    # `{:error, :unreadable}` — a 639-byte document the pass reads until its
    # whole allowance is gone, and before that allowance existed, for ever.
    test "a file that ends in a bracket still finishes", %{user: user, files: files} do
      assert {:ok, _attachment} = upload(user, Fixtures.dangling_bracket_pdf(files))
    end

    # A comment that runs to the end of the buffer and holds a `<<` is the
    # candidate this pass is most easily made to re-read, and a file only has to
    # name `/Launch` once — in a string, harmlessly — to arm the pass at all.
    # Blanking up to the dictionary and resuming there reads it once.
    #
    # Reductions rather than a clock, because the suite runs twenty cases at
    # once (see `Vutuv.WorkCounter`). Calibrated both ways on 2026-09-11: as it
    # stands 60 KB costs 77,683 reductions and the file is accepted, which is
    # the right answer for it. Make `blank_upto_dictionary/6` in
    # `Vutuv.Uploads.PdfGate` reject the range and resume at `at + 1` instead
    # and the same file costs **321 million** and 2.8 seconds of a LiveView's
    # own process, quadrupling with every doubling.
    test "a file cannot make the blanking pass quadratic", %{user: user, files: files} do
      {work, answer} =
        WorkCounter.count_reductions(fn ->
          upload(user, Fixtures.comment_flood_pdf(files, 60_000))
        end)

      assert match?({:ok, _attachment}, answer), "the gate answered: #{inspect(answer)}"
      assert work < 20_000_000, "60 KB of comments cost #{work} reductions"
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

    test "a launch hidden in a stream padded past the inflation cut is refused", %{
      user: user,
      files: files
    } do
      # One `qpdf --object-streams=generate` over a catalog padded to 9 MB puts
      # `/OpenAction << /S /Launch >>` in a ~10 KB file whose only object stream
      # inflates past `@stream_limit`. Skipping that stream (the shape before
      # the fix) accepted it; refusing an unfinished inflate catches it.
      # Calibration: make `scan_streams/2`'s `:too_big` branch skip again and
      # this goes red with `{:ok, _}`. Returns nil without qpdf → skipped.
      case Fixtures.oversized_object_stream_pdf(files) do
        nil -> :ok
        path -> assert {:error, :unreadable} = upload(user, path)
      end
    end

    test "a launch compressed behind a literal endstream is refused", %{user: user, files: files} do
      # A stored deflate block carries the nine bytes `endstream` ahead of a
      # genuinely compressed `/OpenAction << /S /Launch >>`, so `/Launch` is not
      # in the raw bytes and a scan that ended each stream at the first literal
      # `endstream` would inflate only the decoy. Inflating to the deflate
      # stream's own end marker reads the whole thing. Calibration: end
      # `streams/1` at `endstream` again and this goes red with `{:ok, _}`.
      assert {:error, :open_action} = upload(user, Fixtures.endstream_decoy_pdf(files))
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
