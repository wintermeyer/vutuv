defmodule VutuvWeb.RemoteFollowController do
  @moduledoc """
  The "Follow from your own server" button, on a member's profile
  (`POST /:slug/fediverse/follow`) and on an organization page
  (`POST /organizations/:slug/fediverse/follow`, issue #1334).

  A visitor from Mastodon (or any other ActivityPub app) types the address of
  their own account; we resolve their server's follow dialog
  (`Vutuv.Fediverse.RemoteFollow`) and send them there with this account filled
  in, so the follow is confirmed where their account lives. Nothing is stored
  here and no credential ever reaches vutuv — the address is used for one
  lookup and then forgotten.

  **One flow, two kinds of account**, because the visitor is the same person
  asking the same thing: everything below takes a `subject` that is either a
  `%User{}` or an `%Organization{}`, and only the four things that genuinely
  differ are branched — whether it can be followed at all, where a refusal
  lands, what a local follow means, and whether the sentence says "profile" or
  "page". Copying the controller per kind is how the two would drift into
  explaining the same refusal differently.

  It is the one outbound fetch an anonymous visitor can trigger, so it is
  fenced on three sides: the installation switch plus this account actually
  federating (the form is not even rendered otherwise, and a crafted POST is
  refused), a rate limit per IP, and the SSRF/size/timeout guards inside the
  resolver. Every failure lands back on the page with a plain-language
  flash — the handle is there to copy, so there is always a way through.
  """

  use VutuvWeb, :controller

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteFollow
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.Fediverse.Docs
  alias VutuvWeb.RateLimit

  # A lookup is cheap for us and slow for the server we ask, so the budget is
  # generous for a human and useless as a scanning gadget.
  @limit 20
  @window_ms :timer.hours(1)

  def create(conn, params), do: follow(conn, conn.assigns[:user], params["address"] || "")

  @doc """
  The page twin. The slug is resolved through the same visibility gate the page
  itself uses, so a frozen or unverified page answers 404 here rather than
  refusing on a URL that already 404s for the visitor.
  """
  def create_organization(conn, %{"slug" => slug} = params) do
    case Organizations.fetch_visible_organization(slug, conn.assigns[:current_user]) do
      {:error, :not_found} -> ControllerHelpers.render_error(conn, 404)
      {:ok, organization} -> follow(conn, organization, params["address"] || "")
    end
  end

  defp follow(conn, subject, address) do
    cond do
      not followable?(subject) ->
        conn
        |> put_flash(:error, not_federating_message(subject))
        |> back_to(subject)

      RateLimit.check(conn, :remote_follow, nil, limit: @limit, window_ms: @window_ms) ==
          :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> back_to(subject)

      true ->
        resolve(conn, subject, address)
    end
  end

  defp resolve(conn, subject, address) do
    if local_address?(address) do
      follow_here(conn, subject)
    else
      case RemoteFollow.subscribe_url(address, Docs.acct(subject)) do
        {:ok, url} ->
          redirect(conn, external: url)

        {:error, reason} ->
          conn
          |> put_flash(:error, message(reason, address))
          |> back_to(subject)
      end
    end
  end

  # The visitor's "own server" turned out to be this very vutuv. WebFingering
  # it would be vutuv resolving itself (issue #1211's shape) and could only
  # ever route the visitor back here — so no request leaves.
  defp local_address?(address) do
    case RemoteFollow.parse_address(address) do
      {:ok, {_user, host}} -> Fediverse.local_host?(host)
      _ -> false
    end
  end

  # A member of this installation asked to follow this account "from their own
  # server", and their own server is us: give them the thing they asked for, a
  # plain vutuv follow — or, signed out, the way to it.
  defp follow_here(conn, subject) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_flash(:error, sign_in_message(subject))
        |> back_to(subject)

      viewer ->
        conn
        |> flash_local_follow(subject, local_follow(viewer, subject))
        |> back_to(subject)
    end
  end

  defp flash_local_follow(conn, subject, {:ok, {:local_follow, _followee}}) do
    put_flash(
      conn,
      :info,
      gettext("You are on this vutuv yourself, so you now follow @%{handle} right here.",
        handle: subject.username
      )
    )
  end

  defp flash_local_follow(conn, _subject, {:error, :own_account}) do
    put_flash(conn, :error, gettext("That is your own profile. You cannot follow yourself."))
  end

  defp flash_local_follow(conn, subject, {:error, :already_following}) do
    put_flash(
      conn,
      :info,
      gettext("You already follow @%{handle} here.", handle: subject.username)
    )
  end

  defp flash_local_follow(conn, _subject, {:error, _refused}) do
    put_flash(conn, :error, gettext("Something went wrong"))
  end

  # Same gate the card renders on. A **member** who moved their Fediverse
  # account away is followed at the new address, not here; a page cannot move
  # (`moved_to` is a person's decision about their own identity and pages carry
  # no such column), so its gate is the plain one.
  defp followable?(%Organization{} = organization), do: Fediverse.federated?(organization)
  defp followable?(user), do: Fediverse.federated?(user) and not Fediverse.moved?(user)

  defp local_follow(viewer, %Organization{} = organization),
    do: Fediverse.follow_local_organization(viewer, organization)

  defp local_follow(viewer, user), do: Fediverse.follow_local_member(viewer, user)

  # The two sentences that name what the visitor is looking at. Their own
  # msgids rather than an interpolated word: German inflects around it.
  defp not_federating_message(%Organization{}),
    do: gettext("This page is not on the Fediverse.")

  defp not_federating_message(_user), do: gettext("This profile is not on the Fediverse.")

  defp sign_in_message(%Organization{}) do
    gettext("That address is on this vutuv. Sign in and use the Follow button on this page.")
  end

  defp sign_in_message(_user) do
    gettext("That address is on this vutuv. Sign in and use the Follow button on this profile.")
  end

  # Each message names what to do next, never just what failed.
  defp message(:invalid_address, _address) do
    gettext("That is not a Fediverse address. It looks like @you@example.social.")
  end

  defp message(:no_remote_follow, address) do
    gettext(
      "%{server} did not offer a follow dialog. Copy the handle above and paste it into your app's search instead.",
      server: server_name(address)
    )
  end

  defp message(_unreachable, address) do
    gettext(
      "%{server} did not answer. Copy the handle above and paste it into your app's search instead.",
      server: server_name(address)
    )
  end

  # The typed host, echoed back so the message names the server the visitor
  # meant — but only once it parsed, so nothing unvalidated reaches the page.
  defp server_name(address) do
    case RemoteFollow.parse_address(address) do
      {:ok, {_user, host}} -> host
      _ -> gettext("Your server")
    end
  end

  defp back_to(conn, %Organization{} = organization) do
    redirect(conn, to: Organizations.canonical_path(organization) <> "#organization-fediverse")
  end

  defp back_to(conn, user), do: redirect(conn, to: ~p"/#{user}" <> "#profile-fediverse")
end
