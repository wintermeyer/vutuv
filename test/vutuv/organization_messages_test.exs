defmodule Vutuv.OrganizationMessagesTest do
  @moduledoc """
  Writing to a page, and the page answering (issue #1336's last point).

  The model follows the one this milestone already set for posts: the
  conversation belongs to the **page**, so it survives the person who handled
  it; any publisher may read and answer; a reply is sent in the page's name with
  the member who wrote it kept internally; and the page's read state is one
  marker for the whole team, like its activity list.

  The schema turned out not to need the sorted pair generalised. Sorting exists
  to break the symmetry between two ids from the *same* table; a member and a
  page come from different tables, so `(user_a_id, organization_id)` is already
  canonical.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.OAuth
  alias Vutuv.Chat
  alias Vutuv.Chat.Conversation
  alias Vutuv.Chat.Participant
  alias Vutuv.Organizations
  alias Vutuv.Repo
  alias Vutuv.Webhooks
  alias Vutuv.Webhooks.Delivery

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp page_with_publisher do
    owner = insert(:activated_user)
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)
    {page, owner}
  end

  test "the database refuses a conversation naming both other sides or neither" do
    {page, _owner} = page_with_publisher()
    a = insert(:activated_user)
    b = insert(:activated_user)

    assert_raise Ecto.ConstraintError, ~r/conversations_exactly_one_other_side/, fn ->
      Repo.insert!(%Conversation{
        user_a_id: a.id,
        user_b_id: b.id,
        organization_id: page.id,
        initiator_id: a.id
      })
    end

    assert_raise Ecto.ConstraintError, ~r/conversations_exactly_one_other_side/, fn ->
      Repo.insert!(%Conversation{user_a_id: a.id, initiator_id: a.id})
    end
  end

  test "a member opens a conversation with a page, once" do
    {page, _owner} = page_with_publisher()
    member = insert(:activated_user)

    assert {:ok, conversation} = Chat.find_or_create_conversation(member, page)
    assert conversation.user_a_id == member.id
    assert is_nil(conversation.user_b_id)
    assert conversation.organization_id == page.id

    assert {:ok, same} = Chat.find_or_create_conversation(member, page)
    assert same.id == conversation.id
  end

  test "the page's side is one participant row for the whole team" do
    {page, _owner} = page_with_publisher()
    member = insert(:activated_user)

    {:ok, conversation} = Chat.find_or_create_conversation(member, page)

    rows = Repo.all(from(p in Participant, where: p.conversation_id == ^conversation.id))
    assert length(rows) == 2

    # Read means somebody on the team read it, never that everybody did — the
    # same model as the page's activity marker. A row per publisher would also
    # have to be minted and retired as roles change.
    assert Enum.any?(rows, &(&1.user_id == member.id))
    assert Enum.any?(rows, &(&1.organization_id == page.id))
  end

  test "a publisher answers in the page's name, and who typed it stays internal" do
    {page, owner} = page_with_publisher()
    member = insert(:activated_user)

    {:ok, conversation} = Chat.find_or_create_conversation(member, page)
    {:ok, _} = Chat.send_message(member, conversation.id, "Guten Tag.")

    assert {:ok, reply} =
             Chat.send_message_as_organization(page, owner, conversation.id, "Guten Tag zurück.")

    assert reply.sender_organization_id == page.id
    assert is_nil(reply.sender_id)

    # The member who pressed send is recorded, never shown — the same split the
    # authorship work made for posts, and for the same reason: the message
    # belongs to the page and must not leave with the person who typed it.
    assert reply.acting_user_id == owner.id
  end

  test "somebody who may not speak for the page cannot answer" do
    {page, _owner} = page_with_publisher()
    member = insert(:activated_user)
    stranger = insert(:activated_user)

    {:ok, conversation} = Chat.find_or_create_conversation(member, page)

    assert {:error, :not_allowed} =
             Chat.send_message_as_organization(page, stranger, conversation.id, "Hallo.")
  end

  test "a page cannot answer somebody else's conversation" do
    {page, owner} = page_with_publisher()

    other_owner = insert(:activated_user)

    other =
      active_organization_for(other_owner, %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })

    member = insert(:activated_user)
    {:ok, foreign} = Chat.find_or_create_conversation(member, other)

    assert {:error, :not_participant} =
             Chat.send_message_as_organization(page, owner, foreign.id, "Nicht meins.")

    # And a malformed id is "no such conversation", not a crash — the read path
    # has always answered that way, and the send path used to skip the cast.
    assert {:error, :not_participant} =
             Chat.send_message_as_organization(page, owner, "not-a-uuid", "Nicht meins.")
  end

  test "a page nobody may see cannot be written to" do
    {page, _owner} = page_with_publisher()
    member = insert(:activated_user)

    {:ok, _} = Organizations.admin_set_frozen(page, true)

    # Deliberately the STALE struct: the gate re-reads, so a caller holding a
    # copy loaded before the freeze must not get through.
    assert {:error, :frozen} = Chat.find_or_create_conversation(member, page)
  end

  test "the member's own conversation list shows the page, and opening it works" do
    {page, owner} = page_with_publisher()
    member = insert(:activated_user)

    {:ok, conversation} = Chat.find_or_create_conversation(member, page)
    {:ok, _} = Chat.send_message(member, conversation.id, "Guten Tag.")

    # `list_conversations/1` matches on `user_a_id`, so a page conversation was
    # always going to appear here — and then `other_user/2` resolved a nil id.
    # `Repo.one!(where: u.id == ^nil)` RAISES rather than answering nothing, so
    # this was a 500 on the messages page for anybody who wrote to a page.
    [entry] = Chat.list_conversations(member)
    assert entry.conversation.id == conversation.id
    assert %Vutuv.Organizations.Organization{} = entry.other

    assert %Vutuv.Organizations.Organization{id: id} =
             Chat.other_party(conversation, member)

    assert id == page.id

    # And the page's answer counts as unread for the member. `sender_id` is
    # NULL on it, so every `!= me_id` test in the unread machinery had to learn
    # to see it; a badge that stays at zero is how this would have shipped.
    {:ok, _} = Chat.send_message_as_organization(page, owner, conversation.id, "Guten Tag.")

    [entry] = Chat.list_conversations(member)
    assert entry.unread == 1
    assert entry.last_body == "Guten Tag."
  end

  test "the page's team sees the conversation, and the member is its other party" do
    {page, owner} = page_with_publisher()
    member = insert(:activated_user, first_name: "Frida", last_name: "Folger")

    {:ok, conversation} = Chat.find_or_create_conversation(member, page)
    {:ok, _} = Chat.send_message(member, conversation.id, "Guten Tag.")

    [entry] = Chat.list_organization_conversations(page)
    assert entry.conversation.id == conversation.id
    assert entry.last_body == "Guten Tag."
    # The member wrote it, so it is unread for the page's whole team.
    assert entry.unread == 1

    assert %Vutuv.Accounts.User{id: id} = Chat.other_party(conversation, page)
    assert id == member.id

    # Any publisher, not only whoever happened to be addressed.
    assert Organizations.publisher?(page, owner)
  end

  test "the page reads its own thread, and only its own" do
    {page, _owner} = page_with_publisher()
    member = insert(:activated_user)

    {:ok, conversation} = Chat.find_or_create_conversation(member, page)
    {:ok, _} = Chat.send_message(member, conversation.id, "Guten Tag.")

    assert %Conversation{id: id} = Chat.get_conversation(page, conversation.id)
    assert id == conversation.id

    page_of_messages = Chat.messages_page(page, conversation, limit: 20)
    assert [%{body: "Guten Tag."}] = page_of_messages.entries

    # Somebody else's conversation is not the page's to read.
    other_member = insert(:activated_user)
    third = insert(:activated_user)
    {:ok, foreign} = Chat.find_or_create_conversation(other_member, third)
    assert is_nil(Chat.get_conversation(page, foreign.id))
  end

  test "reading marks the thread read for the whole team, not for one publisher" do
    {page, owner} = page_with_publisher()
    second = insert(:activated_user)
    {:ok, _} = Organizations.add_role(page, second, "publisher", owner)
    member = insert(:activated_user)

    {:ok, conversation} = Chat.find_or_create_conversation(member, page)
    {:ok, _} = Chat.send_message(member, conversation.id, "Guten Tag.")

    assert [%{unread: 1}] = Chat.list_organization_conversations(page)

    :ok = Chat.mark_read(page, conversation.id)

    # One marker for the page, so the colleague who did not open it sees the
    # same thing — the model `organizations.activity_read_at` already sets.
    assert [%{unread: 0}] = Chat.list_organization_conversations(page)
  end

  test "a page's reply reaches the member's webhook like any other message" do
    {page, owner} = page_with_publisher()
    member = insert(:activated_user)
    developer = insert(:activated_user)

    redirect = "https://app.example.org/callback"

    {:ok, app, _secret} =
      ApiAuth.create_app(developer, %{"name" => "Hook App", "redirect_uris" => [redirect]})

    {:ok, _subscription, _secret} =
      Webhooks.create_subscription(app, %{
        "url" => "https://hooks.example.org/vutuv",
        "events" => ["message.created"]
      })

    {:ok, request} =
      OAuth.validate_authorize(%{
        "response_type" => "code",
        "client_id" => app.client_id,
        "redirect_uri" => redirect,
        "scope" => "messages:read",
        "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, "vvvvv"), padding: false),
        "code_challenge_method" => "S256"
      })

    {:ok, _code} = OAuth.approve(member, request)

    {:ok, conversation} = Chat.find_or_create_conversation(member, page)

    # The member's own send tells the PAGE, which has no webhooks of its own -
    # so nothing is queued and the recipient id is nil rather than wrong.
    {:ok, _} = Chat.send_message(member, conversation.id, "Guten Tag.")
    assert Repo.aggregate(Delivery, :count) == 0

    # The page answering is an ordinary incoming message for the member, and it
    # was silently the one kind of send that told nobody: the organization path
    # was a second copy of `deliver/4` that had simply left the emit out.
    {:ok, _} = Chat.send_message_as_organization(page, owner, conversation.id, "Ja, gerne.")

    assert [delivery] = Repo.all(Delivery)
    assert delivery.event == "message.created"
    assert delivery.payload["member"] == member.username
    assert delivery.payload["data"]["conversation_id"] == conversation.id
    # A page names itself by its handle when it has claimed one, by its slug
    # when it has not - never nil, which is what `username` alone would give.
    assert delivery.payload["data"]["from"] == page.slug
  end
end
