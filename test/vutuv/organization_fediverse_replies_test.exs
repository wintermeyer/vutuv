defmodule Vutuv.OrganizationFediverseRepliesTest do
  @moduledoc """
  A reply from another network under a **page's** post (issue #1334, completing
  #1069 for pages) — the last thing a page could not receive.

  I had written this up as its own feature. It was not: `fediverse_notes` hangs
  off the post rather than off a member, and the audience a note records is
  decided through `Docs.actor_url/1`, which already knows both kinds. So
  `insert_note/5` needed no change at all, and what was missing was the way in
  and somewhere to show it.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias VutuvWeb.Fediverse.Docs

  @actor "https://social.example/users/alice"

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp published_post(opts \\ []) do
    owner = insert(:activated_user)
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)

    page =
      page
      |> Ecto.Changeset.change(Enum.into(opts, %{fediverse_followers?: true, username: "acme"}))
      |> Repo.update!()

    if page.fediverse_followers?, do: {:ok, _} = Fediverse.ensure_organization_actor(page)
    {:ok, post} = Posts.create_organization_post(page, owner, %{body: "Nach draußen."})
    {page, post}
  end

  defp actor,
    do: %{uri: @actor, handle: "@alice@social.example", name: "Alice", inbox: @actor <> "/inbox"}

  defp reply_activity(page, post, audience \\ ["https://www.w3.org/ns/activitystreams#Public"]) do
    %{
      "type" => "Create",
      "to" => audience,
      "object" => %{
        "id" => "https://social.example/notes/#{System.unique_integer([:positive])}",
        "type" => "Note",
        "content" => "<p>Von drüben geantwortet.</p>",
        "inReplyTo" => Docs.note_url(page, post.id),
        "to" => audience
      }
    }
  end

  test "a public reply is stored under the page's post and raises its reply count" do
    {page, post} = published_post()

    assert :ok = Fediverse.record_organization_reply(page, reply_activity(page, post), actor())

    [note] = Fediverse.list_notes([post.id], nil)[post.id]
    assert note.content_text =~ "Von drüben geantwortet."
    assert note.post_id == post.id

    counts = post.id |> Posts.engagement_counts() |> Posts.shown_counts()
    assert counts.replies == 1
  end

  test "a reply naming another page's post is not stored against this one" do
    {page, _post} = published_post()

    other_owner = insert(:activated_user)

    other =
      active_organization_for(other_owner, %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })

    {:ok, _} = Organizations.add_role(other, other_owner, "publisher", other_owner)
    {:ok, other_post} = Posts.create_organization_post(other, other_owner, %{body: "Woanders."})

    # Addressed to `page` but answering a post that is not its own: the
    # ownership check is what stops one page collecting another's replies.
    assert :skip =
             Fediverse.record_organization_reply(
               page,
               reply_activity(other, other_post),
               actor()
             )

    assert Fediverse.list_notes([other_post.id], nil) == %{}
  end

  test "a page that does not federate receives nothing" do
    {page, post} = published_post(fediverse_followers?: false)

    assert :skip = Fediverse.record_organization_reply(page, reply_activity(page, post), actor())
    assert Fediverse.list_notes([post.id], nil) == %{}
  end

  test "the same reply delivered twice is stored once" do
    {page, post} = published_post()
    activity = reply_activity(page, post)

    assert :ok = Fediverse.record_organization_reply(page, activity, actor())
    assert :skip = Fediverse.record_organization_reply(page, activity, actor())

    assert [_one] = Fediverse.list_notes([post.id], nil)[post.id]
  end

  test "an empty reply earns no row" do
    {page, post} = published_post()

    activity =
      put_in(reply_activity(page, post), ["object", "content"], "<p></p>")

    # A row about a third party has to earn its place; a picture-only or empty
    # note carries nothing to show.
    assert :skip = Fediverse.record_organization_reply(page, activity, actor())
    assert Fediverse.list_notes([post.id], nil) == %{}
  end
end
