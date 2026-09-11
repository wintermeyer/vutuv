defmodule VutuvWeb.MessageAttachmentLiveTest do
  @moduledoc """
  The composer half of files in a message (issue #2110): who is offered a
  picker, what the bubble says while a file is being checked, and that the
  offer is a courtesy rather than the enforcement — the upload is refused
  server-side for a conversation that may carry no files, whether or not the
  control that starts it was ever rendered.

  Not async: it points the global `:uploads_dir_prefix` at a tmp dir, opens
  `ATTACHMENT_UPLOADERS` to members, switches the AI image gate on and turns
  preview pages off — see `setup` for why that last one is load-bearing.
  """

  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.AttachmentHelpers, only: [settled!: 1]
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Chat
  alias Vutuv.Repo
  alias Vutuv.Social

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_msg_live_#{System.unique_integer([:positive])}")
    src = Path.join(tmp, "src")
    File.mkdir_p!(src)
    put_config(:uploads_dir_prefix, tmp)
    put_config(:moderate_images, true)
    on_exit(fn -> File.rm_rf(tmp) end)

    # **No preview pages anywhere in this module.** What is under test is the
    # bubble, never the renderer, and with no pages wanted the pipeline settles
    # a file itself rather than asking a renderer that can fail. A file left
    # unfinished and a bubble deliberately withholding its address are the same
    # HTML, so a failed render would read as the rule under test (#2178; the
    # browser it used to reach is gone from the suite since #2189, and
    # `docs/architecture/attachments.md` has the mechanism).
    Fixtures.put_config(uploaders: :members, preview_pages: 0)

    # Both logins in one place: each drives the real PIN flow and reads the
    # newest mail out of this process's mailbox, so interleaving them with a
    # test's own login hands one of them the other's PIN.
    {sender_conn, sender} = create_and_login_user(conn)
    {other_conn, other} = create_and_login_user(conn)

    # Re-read: the structs the helper hands back predate the confirmation its
    # own PIN flow performed, and `find_or_create_conversation/2` refuses an
    # unconfirmed pair.
    sender = Repo.get!(Vutuv.Accounts.User, sender.id)
    other = Repo.get!(Vutuv.Accounts.User, other.id)

    %{sender_conn: sender_conn, sender: sender, other_conn: other_conn, other: other, src: src}
  end

  defp connected_to(sender, other) do
    follow!(sender, other)
    follow!(other, sender)
    {:ok, conversation} = Chat.find_or_create_conversation(sender, other)
    conversation
  end

  defp stranger_conversation(sender, other) do
    {:ok, conversation} = Chat.find_or_create_conversation(sender, other)
    conversation
  end

  describe "the picker" do
    test "a connected member is offered one", %{sender_conn: conn, sender: sender, other: other} do
      conversation = connected_to(sender, other)

      {:ok, view, _html} = live(conn, ~p"/messages/#{conversation.id}")

      assert has_element?(view, "#add-message-files")
    end

    test "a stranger is not", %{sender_conn: conn, sender: sender, other: other} do
      conversation = stranger_conversation(sender, other)

      {:ok, view, _html} = live(conn, ~p"/messages/#{conversation.id}")

      refute has_element?(view, "#add-message-files")
    end

    test "a connection ended while the composer stood open refuses the upload", context do
      %{sender_conn: conn, sender: sender, other: other, src: src} = context
      conversation = connected_to(sender, other)

      {:ok, view, _html} = live(conn, ~p"/messages/#{conversation.id}")
      assert has_element?(view, "#add-message-files")

      # The picker is on screen and this socket's own assign still says yes;
      # what decides is the question asked when the bytes land.
      %{id: follow_id} = Social.follow_edge(other.id, sender.id)
      Social.unfollow!(other.id, follow_id)

      upload =
        file_input(view, "#message-form", :attachments, [
          %{name: "notes.txt", content: File.read!(Fixtures.text_file(src)), type: "text/plain"}
        ])

      render_upload(upload, "notes.txt")

      # Cancelled rather than kept: nothing was stored and nothing was charged.
      assert Repo.aggregate(Attachment, :count) == 0
      refute has_element?(view, "[data-attachment-chip]")
    end
  end

  describe "the bubble" do
    test "the sender sees the state, the recipient a plain sentence", context do
      %{sender_conn: conn, sender: sender, other: other, src: src} = context
      conversation = connected_to(sender, other)

      {:ok, attachment} =
        Attachments.create_pending(sender, Fixtures.text_file(src), "notes.txt")

      {:ok, _message} =
        Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

      {:ok, view, _html} = live(conn, ~p"/messages/#{conversation.id}")

      assert has_element?(view, "[data-message-file='working']")
      assert render(view) =~ "notes.txt"

      # The other side of the same bubble: a sentence, and no address at all.
      other_conn = context.other_conn
      {:ok, other_view, other_html} = live(other_conn, ~p"/messages/#{conversation.id}")

      refute other_html =~ attachment.token
      assert has_element?(other_view, "[data-message-files]")

      # Once the pipeline is done, the same bubble carries the file.
      settled!(attachment)

      {:ok, _settled_view, settled_html} = live(other_conn, ~p"/messages/#{conversation.id}")
      assert settled_html =~ attachment.token
    end
  end

  describe "the bubble follows the pipeline" do
    test "a file settling reaches an open thread with no reload", context do
      %{sender: sender, other: other, src: src} = context
      conversation = connected_to(sender, other)

      # What is under test is the **broadcast reaching an open thread**, not the
      # renderer, which `setup` has already taken out of the picture.
      {:ok, attachment} =
        Attachments.create_pending(sender, Fixtures.text_file(src), "notes.txt")

      {:ok, _message} =
        Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

      # The recipient is reading the thread while the check is still running.
      {:ok, view, _html} = live(context.other_conn, ~p"/messages/#{conversation.id}")
      assert render(view) =~ "A file is being checked."

      # What the pipeline does when the last verdict lands.
      settled = settled!(attachment)
      Attachments.announce(settled)

      html = render(view)
      assert html =~ attachment.token
      refute html =~ "A file is being checked."
    end
  end

  describe "the bubble says why" do
    test "a settled file the connection no longer covers is not called 'being checked'",
         context do
      %{sender: sender, other: other, src: src} = context
      conversation = connected_to(sender, other)

      {:ok, attachment} =
        Attachments.create_pending(sender, Fixtures.text_file(src), "notes.txt")

      {:ok, _message} =
        Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

      # The connection gate answers ahead of the file's state, so this one would
      # pass just as happily on a file that never finished. `settled!/1` is what
      # holds it to its own premise.
      settled!(attachment)

      %{id: follow_id} = Social.follow_edge(other.id, sender.id)
      Social.unfollow!(other.id, follow_id)

      {:ok, _view, html} = live(context.other_conn, ~p"/messages/#{conversation.id}")

      assert html =~ "only there while the two of you are connected"
      refute html =~ "A file is being checked."
      refute html =~ attachment.token
    end
  end

  describe "German" do
    test "the picker and the waiting line are translated", context do
      %{sender_conn: conn, sender: sender, other: other, src: src} = context
      conversation = connected_to(sender, other)

      {:ok, attachment} =
        Attachments.create_pending(sender, Fixtures.text_file(src), "notes.txt")

      {:ok, _message} =
        Chat.send_message(sender, conversation.id, "hier", attachment_ids: [attachment.id])

      {:ok, _view, html} =
        conn
        |> Phoenix.ConnTest.recycle()
        |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
        |> live(~p"/messages/#{conversation.id}")

      assert html =~ "Dateien hinzufügen"
      # The state word is the one every file surface shares
      # (`PendingPostComponents.file_label/1`), not a second vocabulary.
      assert html =~ "wird vorbereitet"

      # The other side's half of the same bubble, and the new sentences this
      # change added — a one-word msgid is the likeliest to be fuzzy-filled with
      # somebody else's translation and the least likely to be noticed.
      {:ok, _other_view, other_html} =
        context.other_conn
        |> Phoenix.ConnTest.recycle()
        |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
        |> live(~p"/messages/#{conversation.id}")

      assert other_html =~ "Eine Datei wird gerade geprüft."
    end
  end
end
