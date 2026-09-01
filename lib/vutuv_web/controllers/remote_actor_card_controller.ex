defmodule VutuvWeb.RemoteActorCardController do
  @moduledoc """
  The card behind a `@user@host` mention in a post.

  A mention inside remote text was the one remote handle on the site that still
  led straight off it: every other one (a reaction chip, a reply card, the
  author line of a remote post) has landed on `/system/fediverse/account/:id`
  since issue #1162, while a handle *in a sentence* sent the reader to that
  server's own profile. Which is a fine answer to "who is that" and the wrong
  one to "I want their posts here", and the second is what a reader means far
  more often — following meant leaving vutuv, finding the account again, coming
  back and pasting the address into a settings page.

  So the mention keeps its `href` (a middle-click, a copied link and a page
  whose JavaScript never arrived all still go there) and a plain click opens
  this: name, address, self-description, one Follow button, and the two ways
  onward — the account's page here and the original out there.

  **Every action is a POST**, none a GET, and that is deliberate: `show` may
  resolve an address this installation has never seen, which is an outbound
  request to a host somebody else named. As a GET that would be an open-ended
  "go and fetch this" surface reachable by a link, a prefetch or a crawler. The
  account page made the same call for the same reason ("the lookup resolves the
  address as an event and not as a GET"), and a POST behind CSRF and a login is
  what keeps this a member's act rather than anybody's.

  The gates, the hourly budget and every refusal sentence are
  `Vutuv.Fediverse`'s and `VutuvWeb.FediverseComponents`': four surfaces start a
  follow and the member must read the same thing about the same outcome.
  """

  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.RequireLoginOr404)

  # BOTH layouts off. `put_layout` alone drops the chrome and leaves the
  # `:browser` pipeline's root layout on, so every card came back as a whole
  # HTML document — 22 meta tags, six stylesheet links and two scripts — which
  # `innerHTML` happily unwraps into the panel, re-fetching the stylesheets on
  # every open. A fragment endpoint has to say so twice.
  plug(:put_root_layout, html: false)
  plug(:put_layout, html: false)

  alias Vutuv.ContentFilters
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  @doc """
  Who is `address`, and where do I stand with them.

  Answered from the stored account whenever we hold it, which costs nothing and
  is the common case — the accounts a member meets in a post are mostly here
  already. Only an address nobody here has ever stored is resolved, which
  spends one of the member's hourly lookups.
  """
  def show(conn, %{"address" => address}) when is_binary(address) do
    case Fediverse.remote_account_by_address(address) do
      %RemoteAccount{} = account ->
        card(conn, address, account)

      nil ->
        case Fediverse.resolve_remote_account(conn.assigns[:current_user], address) do
          {:ok, account} -> card(conn, address, account)
          {:error, reason} -> card(conn, address, nil, reason)
        end
    end
  end

  @doc """
  Follow the account this card is showing.

  `follow_remote_account/2` rather than `follow_remote/2`: the card has the row
  in front of it, so there is nothing to re-derive from the string — and a real
  actor id is under no obligation to be shaped like an address (the reason that
  split exists). An address we do not hold cannot be followed from here; the
  card said so in the first place, and the member never saw a button.
  """
  def follow(conn, %{"address" => address}) when is_binary(address) do
    case Fediverse.remote_account_by_address(address) do
      %RemoteAccount{} = account ->
        case Fediverse.follow_remote_account(conn.assigns[:current_user], account) do
          {:ok, _follow} -> card(conn, address, account)
          {:error, reason} -> card(conn, address, account, reason)
        end

      nil ->
        card(conn, address, nil, :invalid_address)
    end
  end

  @doc """
  Take the follow back: an accepted one ends, a request nobody answered is
  withdrawn. `unfollow_remote_account/2` is the same withdrawal named by the
  account rather than by the follow row, which is what this card has in hand;
  it answers `{:error, :not_found}` when a second tab got there first, and the
  card that comes back then simply shows Follow again.

  Deliberately **not** falling through to `show/2` when the address is one we do
  not hold: that would re-enter the resolve path, and a DELETE has no business
  spending a slot of the member's hourly budget on two outbound requests.
  """
  def unfollow(conn, %{"address" => address}) when is_binary(address) do
    case Fediverse.remote_account_by_address(address) do
      %RemoteAccount{} = account ->
        Fediverse.unfollow_remote_account(conn.assigns[:current_user], account.id)
        card(conn, address, account)

      nil ->
        card(conn, address, nil, :invalid_address)
    end
  end

  @doc """
  Silence this account, or the whole server it is on — and switch either back.

  Both levers already existed and neither was reachable from the sentence the
  reader is actually looking at: muting an account lived on its own page, and
  muting a server in the feed's settings. "Not this one, not today" is a
  reaction to meeting somebody in a post, so it belongs on the card that opens
  from that meeting.

  The flip itself belongs to `Vutuv.Fediverse` (`toggle_remote_follow_mute/2`,
  `toggle_host_mute/2`), not here. Three surfaces offer these switches and each
  read "what is it now" from something different — a struct held since mount, a
  fresh list, a fresh follow row — so deriving the target state at the call site
  is both a fourth derivation and a race with the member's own second tab.

  A scope nobody offered is not an error — no such control was ever rendered,
  so the honest answer is the card, unchanged.
  """
  def mute(conn, %{"address" => address, "scope" => scope}) when is_binary(address) do
    account = Fediverse.remote_account_by_address(address)

    # The toggle's own answer replaces the viewer this request loaded, and that
    # is not tidiness: the muted-server list is a **column on the member**
    # (`users.feed_muted_hosts`), so the struct the plug put in `assigns` is one
    # write out of date the moment the mute lands. The follow states are re-read
    # from the database and never had the problem; this one silently re-rendered
    # "Mute social.heise.de" onto a server that was now muted, so the press read
    # as having done nothing.
    conn
    |> Plug.Conn.assign(:current_user, apply_mute(conn.assigns[:current_user], account, scope))
    |> card(address, account)
  end

  defp apply_mute(viewer, %RemoteAccount{id: id}, "account") do
    Fediverse.toggle_remote_follow_mute(viewer, id)
    viewer
  end

  defp apply_mute(viewer, %RemoteAccount{host: host}, "host") when is_binary(host) do
    {:ok, viewer} = Fediverse.toggle_host_mute(viewer, host)
    viewer
  end

  defp apply_mute(viewer, _account, _scope), do: viewer

  # The one render. The follow is re-read from the database rather than taken
  # from whatever the act returned, so what the card draws is what is true — a
  # second tab that changed it is then not contradicted by this one.
  defp card(conn, address, account, error \\ nil) do
    viewer = conn.assigns[:current_user]

    summary =
      (account && Fediverse.account_card_summary(account, viewer)) || %{count: 0, latest: nil}

    render(conn, :card,
      address: address,
      account: account,
      follow: account && Fediverse.remote_follow_for(viewer, account),
      blocked_reason: Fediverse.follow_refusal(viewer),
      error: error,
      post_count: summary.count,
      latest: preview(summary.latest, account, viewer),
      host_muted?: account && account.host in Fediverse.muted_hosts(viewer)
    )
  end

  # Which post, if any, the card may quote. Three gates, and each one is a
  # reader's decision this line would otherwise walk straight past.
  #
  # A content warning is the author asking for a click before their words are
  # read, so a preview that ignores it puts them on screen unasked —
  # `RemotePost.warned?/1` and not a bare `sensitive` test, because the two
  # arrive independently and a server that sets only `summary` still asked. A
  # word the member muted is the same promise from the other side; the count
  # line deliberately stays either way, because we do hold the post, they just
  # do not want to read it here.
  defp preview(nil, _account, _viewer), do: nil

  defp preview(%RemotePost{} = post, account, viewer) do
    # The author, put back where the filter looks for it: a rule scoped to an
    # account asks `Posts.account_names/1` who wrote this, which loads the row
    # from the database when the association is not there. It is in hand — by
    # construction this post is that account's.
    post = %{post | remote_account: account}

    if RemotePost.warned?(post) or
         ContentFilters.filtered(post, ContentFilters.compile_for(viewer)),
       do: nil,
       else: post
  end
end
