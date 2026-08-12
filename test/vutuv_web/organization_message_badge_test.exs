defmodule VutuvWeb.OrganizationMessageBadgeTest do
  @moduledoc """
  The shell's message badge while writing as a page (issue #1336 follow-up).

  A page could be written to from v7.264.0 on, but nothing told its team: the
  badge counted the publisher's own inbox whatever identity they were speaking
  as, so the only way to find a message was to open `/messages` on spec. That is
  the difference between a mailbox and a mailbox with a doorbell.

  The count and the live tick are separate mechanisms and both are tested here:
  a badge that is right on load and then frozen looks *worse* than one that is
  always zero, because it invites you to trust it.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag, and because the shell writes to the
  global `VutuvWeb.Presence` topic.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Chat
  alias Vutuv.Organizations
  alias Vutuv.Sessions

  # The same selector the member-side shell tests use.
  @mail_badge ~s(a[title="Messages"] span.bg-accent)

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # The shell is a nested `live_render` inside the page layout, so a `live/2` on
  # any route hands back the PAGE's LiveView, not this one - `send(view.pid, …)`
  # would reach the wrong process. Mounting it isolated is also the honest unit:
  # what is under test is the shell's own count, not the feed's markup.
  defp session_for(user, extra \\ %{}) do
    {token, _session} = Sessions.start_session(user, build_conn(), alert: false)
    Map.merge(%{"session_token" => token, "path" => "/feed"}, extra)
  end

  defp page_with_publisher do
    owner = insert_activated_user()
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)
    {page, owner}
  end

  # The session a publisher's browser carries while switched into the page.
  defp speaking_as(user, page),
    do: session_for(user, %{"acting_as_organization_id" => page.id})

  test "the count is the page's inbox, not the publisher's own", %{conn: conn} do
    {page, owner} = page_with_publisher()

    # Two unread threads for the publisher PERSONALLY, and one for the page.
    # The numbers differ on purpose: a badge reading the wrong inbox would show
    # 2 where it should show 1, which a single-message fixture could not tell
    # apart from the count simply working.
    for greeting <- ["Für Sie persönlich.", "Und noch etwas."] do
      stranger = insert_activated_user()
      {:ok, personal} = Chat.find_or_create_conversation(stranger, owner)
      {:ok, _} = Chat.send_message(stranger, personal.id, greeting)
    end

    member = insert_activated_user()
    {:ok, conversation} = Chat.find_or_create_conversation(member, page)
    {:ok, _} = Chat.send_message(member, conversation.id, "Haben Sie offene Stellen?")

    assert Chat.unread_conversations_count(owner) == 2
    assert Chat.unread_conversations_count(page) == 1

    # Themselves: their own two.
    {:ok, own_shell, _html} =
      live_isolated(conn, VutuvWeb.ShellLive, session: session_for(owner))

    assert has_element?(own_shell, @mail_badge, "2")

    # Speaking as the page: the page's one.
    {:ok, shell, _html} =
      live_isolated(conn, VutuvWeb.ShellLive, session: speaking_as(owner, page))

    assert has_element?(shell, @mail_badge, "1")

    # Reading it as the page clears it for the whole team.
    :ok = Chat.mark_read(page, conversation.id)
    assert Chat.unread_conversations_count(page) == 0
  end

  test "a message to a page is announced on the page's own topic", %{conn: _conn} do
    {page, _owner} = page_with_publisher()
    member = insert_activated_user()

    # What the page's team listens on while speaking as it.
    :ok = Vutuv.Activity.subscribe(page)

    {:ok, conversation} = Chat.find_or_create_conversation(member, page)
    {:ok, _} = Chat.send_message(member, conversation.id, "Guten Tag.")

    # `other_user_id/2` answers nil when the far side is a page, so without a
    # recipient of its own this broadcast went nowhere and the badge only moved
    # on a full reload.
    assert_receive {:new_message, %{conversation_id: id}}
    assert id == conversation.id
  end

  test "the shell recounts the page's inbox when one arrives", %{conn: conn} do
    {page, owner} = page_with_publisher()
    member = insert_activated_user()

    {:ok, shell, _html} =
      live_isolated(conn, VutuvWeb.ShellLive, session: speaking_as(owner, page))

    refute has_element?(shell, @mail_badge)

    {:ok, conversation} = Chat.find_or_create_conversation(member, page)
    {:ok, _} = Chat.send_message(member, conversation.id, "Guten Tag.")

    # Delivered straight to the shell, the way the sibling shell tests do it:
    # PubSub across processes is not deterministic under the SQL sandbox, and
    # the topic itself is covered by the test above.
    send(shell.pid, {:new_message, %{conversation_id: conversation.id}})

    assert has_element?(shell, @mail_badge, "1")
  end

  test "a member who is not speaking as anything still sees their own", %{conn: conn} do
    me = insert_activated_user()
    other = insert_activated_user()

    {:ok, conversation} = Chat.find_or_create_conversation(other, me)
    {:ok, _} = Chat.send_message(other, conversation.id, "Hallo.")

    {:ok, shell, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(me))
    assert has_element?(shell, @mail_badge, "1")
  end

  test "a session naming a page the member may no longer speak for counts their own",
       %{conn: conn} do
    {page, owner} = page_with_publisher()

    stranger = insert_activated_user()
    {:ok, personal} = Chat.find_or_create_conversation(stranger, owner)
    {:ok, _} = Chat.send_message(stranger, personal.id, "Für Sie persönlich.")

    member = insert_activated_user()
    {:ok, conversation} = Chat.find_or_create_conversation(member, page)
    {:ok, _} = Chat.send_message(member, conversation.id, "Guten Tag.")

    role =
      Vutuv.Repo.get_by!(Vutuv.Organizations.OrganizationRole,
        organization_id: page.id,
        user_id: owner.id,
        role: "publisher"
      )

    {:ok, _} = Organizations.remove_role(role)

    # The session still names the page - it is signed, not encrypted, and valid
    # for days - but the mount re-asks the roles, so the badge counts the
    # member's own inbox and the page's mail stays out of reach.
    {:ok, shell, _html} =
      live_isolated(conn, VutuvWeb.ShellLive, session: speaking_as(owner, page))

    assert has_element?(shell, @mail_badge, "1")
    refute has_element?(shell, ~s(#acting-as-banner))
  end
end
