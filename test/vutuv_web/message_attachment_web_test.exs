defmodule VutuvWeb.MessageAttachmentWebTest do
  @moduledoc """
  The one address a message's file has (issue #2110): the authorizing proxy at
  `/system/attachments/:token/…`, which asks the connection gate again on every
  request.

  These are the tests that prove the gate is not merely hidden in the UI. A
  stranger, an outsider and a recipient whose connection has since ended all
  get the proxy's uniform 404 — the same answer an unknown token gets, so the
  URL cannot be used to find out that a file exists.

  Not async: it points the global `:uploads_dir_prefix` at a tmp dir, opens
  `ATTACHMENT_UPLOADERS` to members and switches the AI image gate on, all of
  which every process reads.

  ## Every file here is a PDF, and that is load-bearing (issue #2186)

  The pages really are rendered: this module asserts a preview exists, so it
  cannot turn previews off the way its LiveView sibling did. What it can choose
  is the renderer. A text file's page is drawn by headless Chromium under a
  30-second deadline, and although CI installs poppler alone, the GitHub runner
  image ships Chrome anyway, so a loaded runner misses that deadline,
  `Pages.render/1` records a silent strike and leaves the row at `rendering`
  for the retry (`docs/architecture/attachments.md`). `pdftoppm` has no
  deadline.

  Which matters beyond the flake: `stage: "rendering"` reads as `:working`, and
  this proxy answers a file that is still working with the same uniform 404 it
  gives a refusal, an outsider and an unknown token. So a timed-out render
  satisfies every 404 here for the wrong reason, and `settle!/1` plus the
  premise lines below are what hold each test to its own claim.

  The cost is that this module now needs poppler on the machine running it, as
  `pages_test.exs` and the takedown tests already do: without it the upload
  gate answers `{:error, :pdf_unavailable}` and `sent!/3` raises on the match.
  """

  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.Pages
  alias Vutuv.Chat
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Repo
  alias Vutuv.Social

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_msg_web_#{System.unique_integer([:positive])}")
    src = Path.join(tmp, "src")
    File.mkdir_p!(src)
    put_config(:uploads_dir_prefix, tmp)
    Fixtures.put_config(uploaders: :members)
    put_config(:moderate_images, true)
    on_exit(fn -> File.rm_rf(tmp) end)

    # Both logins in one place: each drives the real PIN flow and reads the
    # newest mail out of this process's mailbox, so interleaving them with a
    # test's own login hands one of them the other's PIN.
    {sender_conn, sender} = create_and_login_user(conn)
    {recipient_conn, recipient} = create_and_login_user(conn)
    {stranger_conn, _stranger} = create_and_login_user(conn)

    # Re-read: the structs the login helper hands back predate the confirmation
    # its own PIN flow performed, and `find_or_create_conversation/2` refuses an
    # unconfirmed pair.
    sender = Repo.get!(Vutuv.Accounts.User, sender.id)
    recipient = Repo.get!(Vutuv.Accounts.User, recipient.id)

    follow!(sender, recipient)
    follow!(recipient, sender)
    {:ok, conversation} = Chat.find_or_create_conversation(sender, recipient)

    %{
      sender_conn: sender_conn,
      sender: sender,
      recipient_conn: recipient_conn,
      recipient: recipient,
      stranger_conn: stranger_conn,
      conversation: conversation,
      src: src
    }
  end

  defp sent!(sender, conversation, path) do
    {:ok, attachment} = Attachments.create_pending(sender, path, Path.basename(path))

    {:ok, _message} =
      Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

    Repo.get!(Attachment, attachment.id)
  end

  # Runs the pipeline and hands back the row it settled, asserting that it
  # settled. That is the line that stops a render which never finished from
  # reading as whatever each test is actually about. `plain_pdf/1` is a
  # one-page document, so no page means a failed render rather than a short
  # one, and the row is re-read so the assertion reads what the database holds
  # rather than the struct the pipeline handed back.
  defp settle!(%Attachment{} = attachment) do
    Pages.render(attachment)

    assert [%ImageRow{} = page] = Pages.list(attachment)
    assert Pages.release(page.id) == :ok

    settled = Repo.get!(Attachment, attachment.id)
    assert Attachments.settled?(settled)
    settled
  end

  describe "the file" do
    test "the recipient downloads it once it has passed", context do
      %{sender: sender, conversation: conversation, src: src} = context
      source = Fixtures.plain_pdf(src)
      attachment = sender |> sent!(conversation, source) |> settle!()

      conn = get(context.recipient_conn, ~p"/system/attachments/#{attachment.token}/file")

      assert conn.status == 200
      assert response(conn, 200) == File.read!(source)
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment;"
      assert disposition =~ "plain.pdf"
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "the recipient gets nothing while the check is still running", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sent!(sender, conversation, Fixtures.plain_pdf(src))

      # Which of this proxy's four 404s this is: the file is not finished.
      refute Attachments.settled?(attachment)

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/file")
             |> response(404)
    end

    test "the sender sees their own file at every stage", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sent!(sender, conversation, Fixtures.plain_pdf(src))

      # "Every stage" is the claim, so name the stage: a settled file would
      # make the 200 below the uninteresting case.
      refute Attachments.settled?(attachment)

      assert context.sender_conn
             |> get(~p"/system/attachments/#{attachment.token}/file")
             |> response(200)
    end

    test "a refused file is not handed to the recipient", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sent!(sender, conversation, Fixtures.plain_pdf(src))
      Pages.render(attachment)

      # The refusal has to be a real one: with no page to refuse, the 404 below
      # would be the unfinished file's and this test would prove nothing, which
      # is exactly how it passed on a timed-out render (issue #2186).
      assert [%ImageRow{} = page] = Pages.list(attachment)
      Pages.page_refused(page)
      assert Attachment.refused?(Repo.get!(Attachment, attachment.id))

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/file")
             |> response(404)
    end

    test "somebody outside the conversation gets the uniform 404", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sender |> sent!(conversation, Fixtures.plain_pdf(src)) |> settle!()

      assert context.stranger_conn
             |> get(~p"/system/attachments/#{attachment.token}/file")
             |> response(404)
    end

    test "a connection ended after the send closes the file again", context do
      %{sender: sender, recipient: recipient, conversation: conversation, src: src} = context
      attachment = sender |> sent!(conversation, Fixtures.plain_pdf(src)) |> settle!()

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/file")
             |> response(200)

      %{id: follow_id} = Social.follow_edge(recipient.id, sender.id)
      Social.unfollow!(recipient.id, follow_id)

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/file")
             |> response(404)
    end

    test "an anonymous visitor gets the same 404 as everybody else", %{conn: conn} do
      # `RequireLoginOr404`, not a redirect to the sign-up form: this proxy's
      # whole posture is that denied and unknown are indistinguishable, and a
      # preview page is fetched by an `<img src>` where a redirect would queue
      # a flash per picture.
      assert conn |> get(~p"/system/attachments/whatever/file") |> response(404)
    end
  end

  describe "the preview" do
    test "the recipient sees the picture once it has passed", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sender |> sent!(conversation, Fixtures.plain_pdf(src)) |> settle!()
      assert [page] = Pages.list(attachment)

      conn =
        get(
          context.recipient_conn,
          ~p"/system/attachments/#{attachment.token}/pages/#{page.position}/lite.avif"
        )

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/avif"]
    end

    # `settle!/1` has already proved page 0 exists and is readable, so this 404
    # is about the version name and nothing else.
    test "an unknown version is a 404, never a path", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sender |> sent!(conversation, Fixtures.plain_pdf(src)) |> settle!()

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/pages/0/original.avif")
             |> response(404)
    end

    # `AttachmentStore.page_dir/2` guards on `position >= 0` and raises rather
    # than answering nothing, so a negative position used to come back a 500
    # instead of this proxy's uniform 404.
    test "a negative position is the same 404, not a crash", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sender |> sent!(conversation, Fixtures.plain_pdf(src)) |> settle!()

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/pages/-1/lite.avif")
             |> response(404)
    end

    test "the recipient sees no preview while the check is still running", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sent!(sender, conversation, Fixtures.plain_pdf(src))
      Pages.render(attachment)

      # Drawn, and held by the AI gate: `Pending.file_state/1`'s
      # still-`pending`-page branch. Both halves, because an unfinished render
      # is `:working` through the stage branch instead, and then the 404 below
      # would be its answer rather than the gate's.
      assert %Attachment{stage: "ready"} = Repo.get!(Attachment, attachment.id)
      assert [%ImageRow{moderation: "pending"} = page] = Pages.list(attachment)

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/pages/#{page.position}/lite.avif")
             |> response(404)
    end
  end
end
