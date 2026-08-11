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

  alias Vutuv.Chat
  alias Vutuv.Chat.Conversation
  alias Vutuv.Chat.Participant
  alias Vutuv.Organizations
  alias Vutuv.Repo

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
             Chat.other_party(conversation, member.id)

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

    assert %Vutuv.Accounts.User{id: id} = Chat.other_party(conversation, page.id)
    assert id == member.id

    # Any publisher, not only whoever happened to be addressed.
    assert Organizations.publisher?(page, owner)
  end
end
