defmodule Vutuv.ChatAttachmentsTest do
  @moduledoc """
  Files and pictures in a private message (issue #2110).

  The whole feature rests on one sentence: nothing travels between members who
  are not **connected** (`Vutuv.Social.connected?/2` — two mutual follows,
  which is what this app calls *vernetzt*). So the gate is asked three times
  and every one of them is tested here: when the file is attached, when the
  message is sent, and again when somebody asks for the bytes — because a
  connection can be ended after the message was sent, and a file still handed
  out then would be exactly the unsolicited file from a stranger the rule
  exists to keep out.

  Beside it sits the second promise: the recipient sees a file only after it
  has passed the format gate and the AI check, while the sender sees the state
  on their own bubble. A file still being worked on, and a file whose preview
  was refused, are both unreadable for the other side and readable for the one
  who sent it.

  `async: false`: the chokepoint writes real files, and the module flips
  `:uploads_dir_prefix` and `:attachments`, which `Application.put_env/3` makes
  global state the SQL sandbox does not roll back.
  """

  use Vutuv.DataCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.Pages
  alias Vutuv.AttachmentStore
  alias Vutuv.Chat
  alias Vutuv.Chat.Message
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Repo
  alias Vutuv.Social

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_msg_files_#{System.unique_integer([:positive])}")
    files = Path.join(tmp, "src")
    File.mkdir_p!(files)
    put_config(:uploads_dir_prefix, tmp)
    # The milestone ships with uploads open to admins alone until a post can
    # hand a file out (#2104). This feature is about what ordinary members do,
    # so the module describes that installation.
    Fixtures.put_config(uploaders: :members)
    # The AI image scan is off by default in the test env; a message's file is
    # held from its recipient until the verdict, so the tests that describe
    # that wait need the gate that produces it.
    put_config(:moderate_images, true)
    Vutuv.RateLimiter.reset()
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp, files: files}
  end

  defp member, do: insert(:activated_user)

  # Two members who follow each other: vernetzt, which is the only shape a file
  # may travel in.
  defp connected_pair do
    a = member()
    b = member()
    follow!(a, b)
    follow!(b, a)
    {:ok, conversation} = Chat.find_or_create_conversation(a, b)
    {a, b, conversation}
  end

  defp upload!(user, path) do
    {:ok, %Attachment{} = attachment} =
      Attachments.create_pending(user, path, Path.basename(path))

    attachment
  end

  # A real picture, written by the same library the derivations use.
  defp picture(dir, name \\ "photo.jpg") do
    path = Path.join(dir, name)
    {:ok, image} = Image.new(120, 80, color: [40, 90, 160])
    {:ok, _} = Image.write(image, path)
    path
  end

  # Everything the pipeline does after the upload, run here rather than waited
  # for: render the preview and let it out of the AI gate.
  defp settle!(%Attachment{} = attachment) do
    Pages.render(attachment)

    for page <- Pages.list(attachment), do: Pages.release(page.id)

    Repo.get!(Attachment, attachment.id)
  end

  describe "the connection gate" do
    test "a file travels between connected members", %{files: files} do
      {sender, recipient, conversation} = connected_pair()
      attachment = upload!(sender, Fixtures.text_file(files))

      assert {:ok, %Message{} = message} =
               Chat.send_message(sender, conversation.id, "have a look",
                 attachment_ids: [attachment.id]
               )

      assert %Attachment{message_id: message_id} = Repo.get!(Attachment, attachment.id)
      assert message_id == message.id
      assert [%Attachment{}] = Chat.message_attachments(message)
      assert Attachments.readable_by?(settle!(attachment), recipient)
    end

    test "a stranger's message refuses the file", %{files: files} do
      sender = member()
      stranger = member()
      {:ok, conversation} = Chat.find_or_create_conversation(sender, stranger)
      attachment = upload!(sender, Fixtures.text_file(files))

      refute Chat.files_allowed?(conversation)

      assert {:error, :files_not_allowed} =
               Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

      # Nothing was claimed and nothing was sent: a refused send is not a
      # message with the files quietly dropped.
      assert Attachments.pending?(Repo.get!(Attachment, attachment.id))
      assert Repo.aggregate(Message, :count) == 0
    end

    test "following one way is not enough", %{files: files} do
      sender = member()
      other = member()
      follow!(other, sender)
      {:ok, conversation} = Chat.find_or_create_conversation(sender, other)
      attachment = upload!(sender, Fixtures.text_file(files))

      refute Chat.files_allowed?(conversation)

      assert {:error, :files_not_allowed} =
               Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])
    end

    test "a page's inbox carries no files at all" do
      put_config(:verify_organization_domains, true)
      {page, _owner} = Vutuv.OrganizationsHelpers.active_organization()
      writer = member()
      {:ok, conversation} = Chat.find_or_create_conversation(writer, page)

      refute Chat.files_allowed?(conversation)
    end

    test "breaking the connection takes the file out of reach for both sides", %{files: files} do
      {sender, recipient, conversation} = connected_pair()
      attachment = upload!(sender, Fixtures.text_file(files))

      {:ok, _message} =
        Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

      attachment = settle!(attachment)
      assert Attachments.readable_by?(attachment, recipient)
      assert Attachments.readable_by?(attachment, sender)

      %{id: follow_id} = Social.follow_edge(recipient.id, sender.id)
      Social.unfollow!(recipient.id, follow_id)

      refute Attachments.readable_by?(Repo.get!(Attachment, attachment.id), recipient)
      refute Attachments.readable_by?(Repo.get!(Attachment, attachment.id), sender)
      # Nothing was deleted: the bytes wait for the connection to come back.
      assert AttachmentStore.served_path(attachment.token)
    end

    test "somebody outside the conversation never reads it", %{files: files} do
      {sender, _recipient, conversation} = connected_pair()
      outsider = member()
      attachment = upload!(sender, Fixtures.text_file(files))

      {:ok, _message} =
        Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

      refute Attachments.readable_by?(settle!(attachment), outsider)
    end
  end

  describe "the recipient waits for the check" do
    test "a file still being worked on is the sender's alone", %{files: files} do
      {sender, recipient, conversation} = connected_pair()
      attachment = upload!(sender, Fixtures.text_file(files))

      {:ok, _message} =
        Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

      attachment = Repo.get!(Attachment, attachment.id)
      refute Attachments.settled?(attachment)
      refute Attachments.readable_by?(attachment, recipient)
      assert Attachments.readable_by?(attachment, sender)
    end

    test "a rendered page still in the AI gate is the sender's alone", %{files: files} do
      {sender, recipient, conversation} = connected_pair()
      attachment = upload!(sender, Fixtures.text_file(files))

      {:ok, _message} =
        Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

      Pages.render(attachment)
      attachment = Repo.get!(Attachment, attachment.id)

      assert [%ImageRow{moderation: "pending"}] = Pages.list(attachment)
      refute Attachments.readable_by?(attachment, recipient)
      assert Attachments.readable_by?(attachment, sender)
    end

    test "a refused file never reaches the recipient", %{files: files} do
      {sender, recipient, conversation} = connected_pair()
      attachment = upload!(sender, Fixtures.text_file(files))

      {:ok, _message} =
        Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

      Pages.render(attachment)
      for page <- Pages.list(attachment), do: Pages.page_refused(page)

      attachment = Repo.get!(Attachment, attachment.id)
      assert Attachment.refused?(attachment)
      refute Attachments.readable_by?(attachment, recipient)
    end
  end

  describe "a picture is an attachment" do
    test "its preview is the picture itself", %{files: files} do
      {sender, recipient, conversation} = connected_pair()
      attachment = upload!(sender, picture(files))

      assert attachment.content_type == "image/jpeg"
      assert Attachment.picture?(attachment)

      {:ok, _message} =
        Chat.send_message(sender, conversation.id, "look", attachment_ids: [attachment.id])

      attachment = settle!(attachment)

      assert [%ImageRow{kind: "attachment_page", position: 0}] = Pages.list(attachment)
      assert Attachments.readable_by?(attachment, recipient)
    end

    test "a file that is not a picture and not a document is refused", %{files: files} do
      sender = member()
      path = Path.join(files, "sneaky.png")
      File.write!(path, "PK\x05\x06" <> :binary.copy(<<0>>, 18))

      assert {:error, :invalid_file} = Attachments.create_pending(sender, path, "sneaky.png")
    end
  end

  describe "files stay as long as the conversation does" do
    test "deleting the message takes its files off disk", %{files: files} do
      {sender, _recipient, conversation} = connected_pair()
      attachment = upload!(sender, Fixtures.text_file(files))

      {:ok, message} =
        Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

      settle!(attachment)
      assert AttachmentStore.served_path(attachment.token)

      {:ok, _} = Chat.delete_message(sender, message)

      refute Repo.get(Attachment, attachment.id)
      refute AttachmentStore.served_path(attachment.token)
      refute AttachmentStore.original_path(attachment.token)
      assert Pages.list(attachment) == []
    end

    test "reopening a declined request takes its files off disk", %{files: files} do
      # A request opened between strangers stays `pending` even once the two
      # connect, so this is the one shape that can hold a file and still be
      # declined — and declining is what wipes a conversation's messages.
      sender = member()
      recipient = member()
      {:ok, conversation} = Chat.find_or_create_conversation(sender, recipient)
      follow!(sender, recipient)
      follow!(recipient, sender)

      attachment = upload!(sender, Fixtures.text_file(files))

      {:ok, _message} =
        Chat.send_message(sender, conversation.id, "here", attachment_ids: [attachment.id])

      {:ok, _} = Chat.decline_request(recipient, conversation.id)
      # The **decliner** re-opening is what wipes the thread; the original
      # requester keeps their declined-but-shown-pending row (issue #779).
      {:ok, _} = Chat.find_or_create_conversation(recipient, sender)

      refute Repo.get(Attachment, attachment.id)
      refute AttachmentStore.served_path(attachment.token)
    end
  end
end
