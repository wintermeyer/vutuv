defmodule VutuvWeb.OrganizationMessagesLiveTest do
  @moduledoc """
  `/messages` when one side is a page (issue #1336).

  There is **no second messages page**. A publisher reads the page's inbox by
  switching into the page (issue #1335's acting-as mode) and opening the same
  `/messages` they always use — the identity the session already carries
  decides whose inbox it is. A separate `/organizations/:slug/messages` would
  have meant two message surfaces to keep in step, and somebody who publishes
  for three pages would have had four inboxes to check.

  The acting-as session value is a **hint, never a credential**: the LiveView
  re-asks the roles on mount like every other surface, so a captured session
  payload naming a page the member no longer speaks for is worth nothing.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Chat
  alias Vutuv.Organizations

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # A page whose owner is nobody this test logs in as.
  defp page_with_owner do
    owner = insert_activated_user()
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)
    # Creating the page mails its owner, and `sent_pin/0` reads the OLDEST mail
    # in the mailbox — leave those there and the next login reads a page notice
    # looking for a six-digit PIN, which fails as "no match of nil".
    drain_emails()
    {page, owner}
  end

  defp drain_emails do
    receive do
      {:email, _} -> drain_emails()
    after
      0 -> :ok
    end
  end

  # Carries the session (and its acting-as value) into the next request the way
  # a browser does.
  defp recycle_login(conn),
    do: conn |> recycle() |> Map.put(:secret_key_base, conn.secret_key_base)

  defp act_as(conn, page),
    do: conn |> post(~p"/organizations/#{page.slug}/act_as") |> recycle_login()

  describe "the member's side" do
    test "the page's conversation is listed and opens", %{conn: conn} do
      {page, owner} = page_with_owner()
      {conn, member} = create_and_login_user(conn)
      # The struct `register_user/2` hands back predates the PIN, so it still
      # reads `email_confirmed?: false` and the gate would refuse them.
      member = Vutuv.Repo.reload!(member)

      {:ok, conversation} = Chat.find_or_create_conversation(member, page)
      {:ok, _} = Chat.send_message(member, conversation.id, "Haben Sie offene Stellen?")
      {:ok, _} = Chat.send_message_as_organization(page, owner, conversation.id, "Ja, mehrere.")

      # The list. `other_user/2` used to resolve a nil id here and RAISE, so
      # this whole page was a 500 for anybody who had written to a page.
      {:ok, _live, html} = live(conn, ~p"/messages")
      assert html =~ page.name

      # And the thread, with the page's answer in it.
      {:ok, _thread, html} = live(conn, ~p"/messages/#{conversation.id}")
      assert html =~ "Ja, mehrere."
      assert html =~ page.name

      # A page is not a member, so nothing offers to block it.
      refute html =~ ~s(id="thread-menu")
    end

    test "the member can still write into it", %{conn: conn} do
      {page, _owner} = page_with_owner()
      {conn, member} = create_and_login_user(conn)
      member = Vutuv.Repo.reload!(member)

      {:ok, conversation} = Chat.find_or_create_conversation(member, page)

      {:ok, live, _html} = live(conn, ~p"/messages/#{conversation.id}")

      live
      |> form("#message-form", message: %{body: "Noch eine Frage."})
      |> render_submit()

      assert render(live) =~ "Noch eine Frage."
    end
  end

  describe "the page's side" do
    test "a publisher acting as the page reads its inbox and answers in its name",
         %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      page = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)

      member = insert_activated_user(first_name: "Frida", last_name: "Folger")
      {:ok, conversation} = Chat.find_or_create_conversation(member, page)
      {:ok, _} = Chat.send_message(member, conversation.id, "Haben Sie offene Stellen?")

      conn = act_as(conn, page)

      # The same URL, a different inbox: the member who wrote in, not the
      # publisher's own conversations.
      {:ok, _live, html} = live(conn, ~p"/messages")
      assert html =~ "Frida Folger"

      {:ok, thread, _html} = live(conn, ~p"/messages/#{conversation.id}")

      thread
      |> form("#message-form", message: %{body: "Ja, mehrere."})
      |> render_submit()

      assert render(thread) =~ "Ja, mehrere."

      # It left in the page's name, with the publisher recorded but not shown.
      entries = Chat.messages_page(page, conversation, limit: 20).entries
      reply = List.first(entries)
      assert reply.body == "Ja, mehrere."
      assert reply.sender_organization_id == page.id
      assert is_nil(reply.sender_id)
      assert reply.acting_user_id == owner.id
    end

    test "somebody who stopped being a publisher no longer reaches the inbox", %{conn: conn} do
      {page, owner} = page_with_owner()
      {conn, helper} = create_and_login_user(conn)
      {:ok, _} = Organizations.add_role(page, helper, "publisher", owner)

      member = insert_activated_user()
      {:ok, conversation} = Chat.find_or_create_conversation(member, page)
      {:ok, _} = Chat.send_message(member, conversation.id, "Guten Tag.")

      conn = act_as(conn, page)

      {:ok, _live, html} = live(conn, ~p"/messages")
      assert html =~ "Guten Tag."

      # The role goes away while the session still names the page. The mount
      # re-asks rather than trusting the session, so they are themselves again
      # and see their own (empty) inbox instead of the page's.
      role_row =
        Vutuv.Repo.get_by!(Vutuv.Organizations.OrganizationRole,
          organization_id: page.id,
          user_id: helper.id,
          role: "publisher"
        )

      {:ok, _} = Organizations.remove_role(role_row)

      {:ok, _live, html} = live(conn, ~p"/messages")
      refute html =~ "Guten Tag."
    end
  end

  describe "getting there" do
    test "the page offers a Message button, and it opens the conversation", %{conn: conn} do
      {page, _owner} = page_with_owner()
      {conn, member} = create_and_login_user(conn)
      _ = member

      {:ok, _live, html} = live(conn, ~p"/organizations/#{page.slug}")
      assert html =~ ~s(data-message-organization)

      # Follow the button's own href rather than a path this test invented: a
      # hand-built route proves nothing about what the page actually links to.
      [tag] = Regex.run(~r/<a[^>]*id="message-organization"[^>]*>/, html)
      [_, href] = Regex.run(~r/href="([^"]+)"/, tag)

      # It finds-or-creates, then hands over to the thread.
      assert {:error, {:live_redirect, %{to: thread_path}}} = live(conn, href)
      {:ok, _thread, html} = live(conn, thread_path)
      assert html =~ page.name
    end

    test "a page that nobody may see cannot be written to", %{conn: conn} do
      {page, _owner} = page_with_owner()
      {:ok, _} = Organizations.admin_set_frozen(page, true)

      {conn, _member} = create_and_login_user(conn)

      assert {:error, {:live_redirect, %{to: "/messages"}}} =
               live(conn, ~p"/messages/organization/#{page.slug}")
    end

    test "a publisher writing as the page is not offered a button to itself", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      page = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)

      conn = act_as(conn, page)

      {:ok, _live, html} = live(conn, ~p"/organizations/#{page.slug}")
      refute html =~ ~s(data-message-organization)
    end
  end
end
