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
  """

  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.Pages
  alias Vutuv.Chat
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

  defp settle!(%Attachment{} = attachment) do
    Pages.render(attachment)
    for page <- Pages.list(attachment), do: Pages.release(page.id)
    Repo.get!(Attachment, attachment.id)
  end

  describe "the file" do
    test "the recipient downloads it once it has passed", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sender |> sent!(conversation, Fixtures.text_file(src)) |> settle!()

      conn = get(context.recipient_conn, ~p"/system/attachments/#{attachment.token}/file")

      assert conn.status == 200
      assert response(conn, 200) =~ "Just some notes."
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment;"
      assert disposition =~ "notes.txt"
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "the recipient gets nothing while the check is still running", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sent!(sender, conversation, Fixtures.text_file(src))

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/file")
             |> response(404)
    end

    test "the sender sees their own file at every stage", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sent!(sender, conversation, Fixtures.text_file(src))

      assert context.sender_conn
             |> get(~p"/system/attachments/#{attachment.token}/file")
             |> response(200)
    end

    test "a refused file is not handed to the recipient", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sent!(sender, conversation, Fixtures.text_file(src))
      Pages.render(attachment)
      for page <- Pages.list(attachment), do: Pages.page_refused(page)

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/file")
             |> response(404)
    end

    test "somebody outside the conversation gets the uniform 404", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sender |> sent!(conversation, Fixtures.text_file(src)) |> settle!()

      assert context.stranger_conn
             |> get(~p"/system/attachments/#{attachment.token}/file")
             |> response(404)
    end

    test "a connection ended after the send closes the file again", context do
      %{sender: sender, recipient: recipient, conversation: conversation, src: src} = context
      attachment = sender |> sent!(conversation, Fixtures.text_file(src)) |> settle!()

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
      attachment = sender |> sent!(conversation, Fixtures.text_file(src)) |> settle!()
      assert [page] = Pages.list(attachment)

      conn =
        get(
          context.recipient_conn,
          ~p"/system/attachments/#{attachment.token}/pages/#{page.position}/lite.avif"
        )

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/avif"]
    end

    test "an unknown version is a 404, never a path", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sender |> sent!(conversation, Fixtures.text_file(src)) |> settle!()

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/pages/0/original.avif")
             |> response(404)
    end

    # `AttachmentStore.page_dir/2` guards on `position >= 0` and raises rather
    # than answering nothing, so a negative position used to come back a 500
    # instead of this proxy's uniform 404.
    test "a negative position is the same 404, not a crash", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sender |> sent!(conversation, Fixtures.text_file(src)) |> settle!()

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/pages/-1/lite.avif")
             |> response(404)
    end

    test "the recipient sees no preview while the check is still running", context do
      %{sender: sender, conversation: conversation, src: src} = context
      attachment = sent!(sender, conversation, Fixtures.text_file(src))
      Pages.render(attachment)
      assert [page] = Pages.list(attachment)

      assert context.recipient_conn
             |> get(~p"/system/attachments/#{attachment.token}/pages/#{page.position}/lite.avif")
             |> response(404)
    end
  end
end
