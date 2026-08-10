defmodule Vutuv.OrganizationPostEngagementTest do
  @moduledoc """
  What happens when members act on a post an organization published (issue
  #1334). Since v7.242.0 such posts reach feeds, so every engagement path meets
  a post whose `user_id` is **nil** — and several of them were written when that
  could not happen.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag, and because two of these tests insert a
  webhook subscription, which is the condition that makes the emit path run at
  all.
  """
  use Vutuv.DataCase, async: false

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

  defp organization_post(body \\ "Von uns.") do
    {organization, owner} = active_organization()
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {:ok, post} = Posts.create_organization_post(organization, owner, %{body: body})
    {organization, owner, post}
  end

  describe "liking, reposting and bookmarking" do
    test "a member may like an organization post" do
      {_organization, _owner, post} = organization_post()
      member = insert(:activated_user)

      assert :ok = Posts.like_post(member, post)
      assert Posts.post_engagement(post.id, member).liked?
    end

    test "a member may repost and bookmark one" do
      {_organization, _owner, post} = organization_post()
      member = insert(:activated_user)

      assert :ok = Posts.repost_post(member, post)
      assert :ok = Posts.bookmark_post(member, post)

      engagement = Posts.post_engagement(post.id, member)
      assert engagement.reposted?
      assert engagement.bookmarked?
    end

    test "liking still works when a webhook subscription exists" do
      # The regression: `Vutuv.Webhooks.emit/3` only reaches its query when some
      # subscription is listening, and that query compared `g.user_id` with the
      # post author — nil here, which Ecto **raises** on rather than treating as
      # "matches nothing". So the bug was invisible until an installation had
      # its first `post.liked` subscriber.
      Repo.insert!(%Vutuv.Webhooks.Subscription{
        app_id: insert(:oauth_app).id,
        url: "https://example.com/hook",
        secret: "s3cret",
        events: ["post.liked"],
        active?: true
      })

      {_organization, _owner, post} = organization_post()
      member = insert(:activated_user)

      assert :ok = Posts.like_post(member, post)
    end
  end

  describe "reporting" do
    test "an organization post is reportable, and answers to whoever claimed the page" do
      {_organization, owner, post} = organization_post()
      reporter = insert(:activated_user)

      # Not merely "does not crash": content sitting in everybody's feed has to
      # be reportable, and the ⋯ menu offers the control.
      assert Vutuv.Moderation.can_report?(reporter, post)

      assert {:ok, _case} =
               Vutuv.Moderation.report_content(reporter, post, %{
                 category: "spam",
                 details: "Unerwünscht."
               })

      # The strike ladder sits with the member who claimed the page, the same
      # rule the organization page itself already follows — not with whoever
      # happened to press publish.
      assert Vutuv.Moderation.open_case_for(post).owner_id == owner.id
    end

    test "the page's own publisher cannot report it" do
      {_organization, owner, post} = organization_post()

      # `owner_id/1` resolves to them, so this is the "own content" refusal.
      assert {:error, :own_content} =
               Vutuv.Moderation.report_content(owner, post, %{category: "spam"})
    end
  end

  describe "mentions" do
    test "a mention in an organization post names the organization, not nobody" do
      mentioned = insert(:activated_user, username: "mentionedmember")
      {organization, _owner, _post} = organization_post("Hallo @#{mentioned.username}!")

      # The notification the mentioned member sees has to say who spoke. Before
      # this it carried a nil actor — no name, no link, no picture — because the
      # actor was read as `post.user`.
      page = Vutuv.Activity.notifications_page(mentioned.id)
      [notification | _] = page.entries

      assert notification.actor_name == organization.name
      assert notification.actor_param == organization.slug
    end
  end
end
