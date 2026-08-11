defmodule VutuvWeb.OrganizationMentionNotificationTest do
  @moduledoc """
  A member named by a post an organization published (issues #1334, #1336).

  This is the **chained** consequence of letting a page mention somebody: the
  notification reaches the member, so the notifications page now renders a post
  with no member author. It hand-built that post's permalink from
  `post.user`, so the page raised `cannot convert nil to param` — a member's own
  notifications, broken by a page naming them.

  Two things were wrong and both are worth a test: the quoted posts were
  preloaded with `:user` alone, and the permalink was assembled at the call site
  instead of asked of `Vutuv.Posts.path/1`, which is the only function that
  knows a post can have two kinds of author.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  test "their notifications open, quote the post and link to it", %{conn: conn} do
    {conn, member} = create_and_login_user(conn)
    {organization, owner} = active_organization()
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

    {:ok, post} =
      Posts.create_organization_post(organization, owner, %{
        body: "Willkommen @#{member.username}!"
      })

    {:ok, _view, html} = live(conn, ~p"/notifications")

    # The organization is named as the actor — not the member who published.
    assert html =~ organization.name
    refute html =~ owner.username
    # …and the quote links to the post under the organization's own permalink.
    assert html =~ Posts.path(post)
  end
end
