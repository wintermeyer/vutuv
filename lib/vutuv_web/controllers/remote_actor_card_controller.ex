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
  alias Vutuv.PostRewrites
  alias VutuvWeb.PostTeaser

  # How much of a quote the card ever shows: two clamped lines on the newest and
  # one truncated line on each of the others, at 20rem. The default 200 shipped
  # about twice this and CSS hid the rest.
  @quote_length 120

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
  #
  # `context` and `expanded` come off `conn.params` rather than travelling
  # through the four actions: both say what the reader has in front of them —
  # which post is open *behind* the card, and whether they have opened its
  # drawer — which is a fact about the request and not about the act. Every act
  # re-renders the whole card, so anything the client does not send back is lost
  # on the next press: a quote that appears only once Follow is pressed, or a
  # drawer that folds itself away, is the card contradicting itself over one
  # click.
  defp card(conn, address, account, error \\ nil) do
    viewer = conn.assigns[:current_user]

    summary =
      (account && Fediverse.account_card_summary(account, viewer)) ||
        %{count: 0, last_at: nil, posts: []}

    quotes = quotes(summary.posts, account, viewer, conn.params["context"])

    render(conn, :card,
      address: address,
      account: account,
      follow: account && Fediverse.remote_follow_for(viewer, account),
      blocked_reason: Fediverse.follow_refusal(viewer),
      error: error,
      post_count: summary.count,
      last_at: summary.last_at,
      # Split here rather than in the template: which quote is the headline and
      # which are the sample is the same decision as which posts may be quoted
      # at all, and that one is stated to be the controller's.
      newest: List.first(quotes),
      older: Enum.drop(quotes, 1),
      expanded?: conn.params["expanded"] == "1",
      host_muted?: account && account.host in Fediverse.muted_hosts(viewer)
    )
  end

  # Which of the account's posts the card may quote, newest first, each with the
  # one line it is shown as and whether it really is the account's latest.
  #
  # **The post the reader has open** is this card's own gate, and the only one
  # that is not about permission: a card opened from the author line of a post
  # quotes that post back at the reader as the freshest thing the account wrote,
  # which spends its most valuable line saying what is on the screen behind it.
  # Drop it and the next one moves up — the count and the clock stay the
  # account's, because they are facts about the account and not about this card,
  # and `latest?` is how the quote that moved up stops calling itself the latest.
  #
  # It comes first so that a card with nothing else to quote never asks the
  # database for a filter set nobody then consults.
  defp quotes(posts, account, viewer, context) do
    posts
    |> Enum.reject(&(&1.id == context))
    |> quotable(account, viewer, List.first(posts))
  end

  defp quotable([], _account, _viewer, _newest), do: []

  # The rest of the gates belong to the reader, and `PostTeaser.record_line/4`
  # owns them — their search-and-replace rules first, then their content
  # filters over what those left, then the one line. That order is not this
  # module's to restate (reversed, a filter judges a line the reader was never
  # going to see), and the card is the fourth surface over these same rows.
  #
  # A **content warning** stays here, because it is the author's decision rather
  # than the reader's: it is the author asking for a click before their words
  # are read, so a quote that ignores it puts them on screen unasked.
  # `RemotePost.warned?/1` and not a bare `sensitive` test, because the two
  # arrive independently and a server that sets only `summary` still asked. The
  # count line deliberately stays whatever these drop, because we do hold the
  # posts, the reader just may not be shown them here.
  defp quotable(posts, account, viewer, newest) do
    filters = ContentFilters.compile_for(viewer)
    # One account, so one set of rules for every post on the card — the card is
    # about that account, which is exactly what `author_rules/2` answers.
    rewrites = PostRewrites.author_rules(viewer, account)

    posts
    # The author, put back where both passes look for it: a rule scoped to an
    # account asks `Posts.account_names/1` who wrote this, which loads the row
    # from the database when the association is not there. It is in hand — by
    # construction these posts are that account's.
    |> Stream.map(fn %RemotePost{} = post -> %{post | remote_account: account} end)
    |> Stream.reject(&RemotePost.warned?/1)
    |> Stream.map(&quote_entry(&1, rewrites, filters, newest))
    |> Stream.reject(&is_nil(&1.line))
    |> Enum.take(Fediverse.card_quotes())
  end

  defp quote_entry(post, rewrites, filters, newest) do
    %{
      post: post,
      line: PostTeaser.record_line(post, rewrites, filters, length: @quote_length),
      latest?: newest != nil and post.id == newest.id
    }
  end
end
