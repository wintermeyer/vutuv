defmodule VutuvWeb.OrganizationManageGateTest do
  @moduledoc """
  An organization's management LiveView must re-check the actor's role on the
  socket, not trust the controller that embedded it.

  `OrganizationController.manage/4` is the only permission check these pages
  had: it asks the page's own predicate, then hands the LiveView an
  `organization_id` in a `live_render` session — signed, **not** encrypted,
  bound to no user and good for days. A role taken away after that render did
  not reach the open tab, and a reconnect (every deploy causes one) re-mounted
  with the same map. `Vutuv.Organizations.set_roles/4`'s own docstring names
  this attack; only `Roles` and `Apps` were re-checking.

  The sibling of `embedded_subject_gate_test.exs`: that one asks whether the
  **subject** may be shown, this one whether the **actor** may still act. A new
  page under `OrganizationController.manage/4` belongs in `@managed`.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations

  # Each entry: the LiveView, the role that reaches it, and the predicate the
  # controller gates it with — kept in the same order as the controller's
  # actions so the two lists can be read side by side.
  @managed [
    {VutuvWeb.OrganizationLive.Edit, "owner", "Edit"},
    {VutuvWeb.OrganizationLive.Roles, "owner", "Roles"},
    {VutuvWeb.OrganizationLive.Domains, "owner", "Domains"},
    {VutuvWeb.OrganizationLive.Fediverse, "owner", "Fediverse"},
    {VutuvWeb.OrganizationLive.Exclusions, "owner", "Exclusions"},
    {VutuvWeb.OrganizationLive.Activity, "owner", "Activity"},
    {VutuvWeb.OrganizationLive.Feed, "publisher", "Feed"},
    {VutuvWeb.OrganizationLive.Following, "publisher", "Following"}
  ]

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  for {live_view, role, label} <- @managed do
    test "#{label} refuses a member whose #{role} role was taken away" do
      {organization, owner} = active_organization()
      member = insert_activated_user()

      {:ok, _} = Organizations.set_roles(organization, member, [unquote(role)], owner)

      # The premise: with the role, the page really does mount — so a failure
      # below is the gate missing, not the fixture being wrong.
      assert {:ok, _view, _html} = mount_managed(unquote(live_view), organization, member)

      {:ok, _} = Organizations.set_roles(organization, member, [], owner)

      refute renders?(unquote(live_view), organization, member),
             "#{unquote(label)} still served a member whose role was revoked"
    end
  end

  # A real session token, the only identity these LiveViews trust (#1036), so
  # the actor is authenticated the way a browser authenticates them rather than
  # by a curated `user_id` the socket would rightly ignore.
  defp mount_managed(live_view, organization, actor) do
    session =
      shell_session(actor, %{"organization_id" => organization.id, "locale" => "en"})

    live_isolated(build_conn(), live_view, session: session)
  end

  # A gate may refuse by redirecting away or by not mounting at all; either is a
  # refusal. Only a live mount that stays on the page is not.
  defp renders?(live_view, organization, actor) do
    case mount_managed(live_view, organization, actor) do
      {:ok, _view, _html} -> true
      {:error, _redirect_or_reason} -> false
    end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end
end
