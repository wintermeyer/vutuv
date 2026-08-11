defmodule Vutuv.OrganizationFediverseReactionsTest do
  @moduledoc """
  A page's post can be favourited or re-shared on another network, and the team
  sees it (issue #1334, completing #1068 for pages).

  Without this a page publishes outward and learns nothing back: its post could
  travel and the team would read a flat zero. The counts needed no work —
  `fediverse_reactions` hangs off the post, not off a member, so
  `Posts.shown_counts/1` folds a stored row in by itself. What was missing was
  only the way in.

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

  defp counts(post), do: post.id |> Posts.engagement_counts() |> Posts.shown_counts()

  test "a Like from another network raises the page post's like count" do
    {page, post} = published_post()

    assert counts(post).likes == 0

    :ok =
      Fediverse.record_organization_reaction(
        page,
        Docs.note_url(page, post.id),
        "like",
        %{uri: @actor, handle: "@alice@social.example"}
      )

    assert counts(post).likes == 1
  end

  test "an Announce raises the repost count, and an Undo takes it back" do
    {page, post} = published_post()
    uri = Docs.note_url(page, post.id)

    :ok = Fediverse.record_organization_reaction(page, uri, "announce", %{uri: @actor})
    assert counts(post).reposts == 1

    # Unconditional by design: an upstream withdrawal is the deletion path that
    # makes storing somebody else's act defensible in the first place.
    :ok = Fediverse.remove_organization_reaction(page, uri, "announce", @actor)
    assert counts(post).reposts == 0
  end

  test "the same actor liking twice counts once" do
    {page, post} = published_post()
    uri = Docs.note_url(page, post.id)

    :ok = Fediverse.record_organization_reaction(page, uri, "like", %{uri: @actor})
    :ok = Fediverse.record_organization_reaction(page, uri, "like", %{uri: @actor})

    # A redelivery is normal traffic, not a second favourite.
    assert counts(post).likes == 1
  end

  test "a Like naming another page's post is not recorded against this one" do
    {page, _post} = published_post()

    other_owner = insert(:activated_user)

    other =
      active_organization_for(other_owner, %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })

    {:ok, _} = Organizations.add_role(other, other_owner, "publisher", other_owner)

    {:ok, other_post} =
      Posts.create_organization_post(other, other_owner, %{body: "Woanders."})

    # Addressed to `page` but naming a post that is not its own: the ownership
    # check is the point, or one page could inflate another's counts.
    assert :skip =
             Fediverse.record_organization_reaction(
               page,
               Docs.note_url(other, other_post.id),
               "like",
               %{uri: @actor}
             )

    assert counts(other_post).likes == 0
  end

  test "a page that does not federate collects nothing" do
    {page, post} = published_post(fediverse_followers?: false)

    assert :skip =
             Fediverse.record_organization_reaction(
               page,
               Docs.note_url(page, post.id),
               "like",
               %{uri: @actor}
             )

    assert counts(post).likes == 0
  end
end
