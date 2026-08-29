defmodule Vutuv.NodeInfo do
  @moduledoc """
  NodeInfo (issue #1448): the small JSON document the fediverse's directory
  layer reads to learn that this server exists and what it runs.

  FediDB, the-federation.info and Fediverse Observer all discover a server the
  same way: fetch `/.well-known/nodeinfo`, follow the highest-version link they
  understand, read the document. An installation without it can federate
  perfectly, be followed from anywhere, and still be invisible to every list a
  person consults when they go looking for federated software — there is
  nothing for those sites to detect.

  ## What this says, and what it deliberately does not

  Both schema versions are served. **2.0** is what every consumer understands;
  **2.1** adds `software.repository` and `software.homepage`, which points a
  directory straight at the source of an open-source project. The two are the
  same document apart from those fields.

  `software.name`, `repository` and `homepage` describe **vutuv the software**,
  not the party running this copy of it, so they are literals here and not
  operator config — every installation runs the same software, developed in the
  same repository. What names the operator (`metadata.nodeName`,
  `nodeDescription`) sits behind the Operator identity block in
  `config/config.exs` like every other such value.

  ## What the description claims, and who may claim it

  A directory prints `nodeDescription` verbatim beside the entry, so every word
  of it is a public claim made in the operator's name — which is why the default
  states only what is true of the **software** on every installation: it is
  MIT-licensed, it sets one first-party cookie and it loads nothing from another
  host. An operator who never edits the string still says nothing false.

  Where the servers stand is the one claim of the four that is **not** a
  property of the software, so it is not in the string: `node_description/0`
  appends it from `:data_location`, which drops out entirely for an operator on
  rented cloud infrastructure. That is the same split the start page's "Your
  data" cards make, and `VutuvWeb.PageHTML.data_location/0` is the single place
  that decides whether the claim was made at all. What this deliberately does
  **not** say is that we are the good ones: every server in that list claims as
  much, so the claim carries no information, and the facts above are the same
  statement in a form a reader can check.

  The rest of `metadata` is what a person reading a directory entry can act on:
  `langs` (the locales served), `maintainer` (the operator contact
  `/.well-known/security.txt` already publishes), and `tosUrl` /
  `privacyPolicyUrl` — the last two only once that page has actually been
  written, since a link to a "not published yet" placeholder is worse than no
  link at all.

  The figures are the part worth being careful about:

    * **`usage.users.total` is the members here** (`Accounts.count_users/0`) and
      never the top bar's people total (`Vutuv.PeopleCounter`). That number adds
      the remote accounts following this installation, which are other servers'
      accounts — publishing them here would double-count them across the
      network. The exact query is used rather than the cached counter because
      this document is fetched a handful of times a day, and because the cell
      reads 0 for the first moments after a deploy, which is exactly when a
      polling directory would record this installation as empty.

    * **`activeMonth` / `activeHalfyear`** are the members with a signed-in
      device seen inside the window (`user_sessions.last_seen_at`, bumped on
      every request). That is what the specification means — "signed in at
      least once in the last 30 / 180 days" — so the figure is comparable with
      what other implementations publish. A revoked session still counts: the
      member did sign in, and logging out afterwards does not undo that. Both
      are drawn from the same member population as `total`, so neither can
      exceed it.

    * **`localPosts` / `localComments`** count what an **anonymous** reader can
      see (`Posts.scope_visible/2` with no viewer), split by whether the post
      answers another one. Nothing new is disclosed: those posts are already in
      the sitemap and the RSS feeds. A private, frozen or still-moderated post
      is in neither figure.

  `openRegistrations` is hardcoded `true` because it is true: there is no
  registration gate in vutuv, so anybody who reaches an installation can sign
  up. It is deliberately *not* a config flag — a flag that changed only the
  advertised value while the sign-up form kept accepting everybody would be a
  worse answer than the honest one. The day a real gate exists, this reads it.

  `protocols` says `activitypub` on every installation, including one running
  `FEDIVERSE_ENABLED=false`: it names the protocol the software speaks, the
  schema requires at least one entry, and a directory that follows it finds the
  actor endpoints answering 404 — which is the same thing said twice.
  """

  import Ecto.Query

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.BuildInfo
  alias Vutuv.Languages
  alias Vutuv.Legal
  alias Vutuv.Legal.LegalPage
  alias Vutuv.Moderation.Query, as: ModerationQuery
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Sessions.UserSession
  alias Vutuv.SourceRepo
  alias VutuvWeb.Endpoint
  alias VutuvWeb.PageHTML

  require ModerationQuery

  # Newest first: a consumer picks the highest version it understands.
  @versions ["2.1", "2.0"]
  @rel_prefix "http://nodeinfo.diaspora.software/ns/schema/"

  # Under /system/ rather than at the `/nodeinfo` root word, which member
  # handles own. The specification does not fix the path — the link document
  # below is what says where the document lives, which is why Mastodon,
  # Pleroma and Misskey all serve it somewhere different.
  @path_prefix "/system/nodeinfo/"

  # Properties of the software. The name is identical on every installation;
  # the repository is not — a fork owes its users its own source, so it comes
  # from `Vutuv.SourceRepo`.
  @software_name "vutuv"
  # The apex, not the `www.` alias: production 301s `www.` here, so the alias
  # would send every directory through a redirect to reach the same page.
  @homepage "https://vutuv.de"

  # The active-user windows the specification defines.
  @month_days 30
  @halfyear_days 180

  @doc "The schema versions this installation serves, newest first."
  def versions, do: @versions

  @doc """
  The `links` of the `/.well-known/nodeinfo` link document: one entry per
  served schema version, each an absolute URL of this installation.
  """
  def links do
    Enum.map(@versions, fn version ->
      %{"rel" => @rel_prefix <> version, "href" => Endpoint.url() <> @path_prefix <> version}
    end)
  end

  @doc """
  The NodeInfo document for `version` (`"2.0"` or `"2.1"`), or `nil` for a
  version this installation does not serve.
  """
  def document(version) when version in @versions do
    usage = usage()

    %{
      "version" => version,
      "software" => software(version),
      "protocols" => ["activitypub"],
      "services" => %{"inbound" => [], "outbound" => []},
      "openRegistrations" => true,
      "usage" => %{
        "users" => %{
          "total" => usage.users.total,
          "activeMonth" => usage.users.active_month,
          "activeHalfyear" => usage.users.active_halfyear
        },
        "localPosts" => usage.local_posts,
        "localComments" => usage.local_comments
      },
      "metadata" => metadata()
    }
  end

  def document(_version), do: nil

  # `metadata` is the schema's free-form half. Four of these are what a person
  # reading a directory entry can act on; the two legal URLs appear only once
  # the operator has actually written that page, because a link to a
  # "not published yet" placeholder is worse than no link.
  defp metadata do
    {maintainer_name, maintainer_email} = Application.fetch_env!(:vutuv, :operator_recipient)

    %{
      "nodeName" => Application.fetch_env!(:vutuv, :node_name),
      "nodeDescription" => node_description(),
      "langs" => locales(),
      "maintainer" => %{"name" => maintainer_name, "email" => maintainer_email}
    }
    |> put_legal_url("tosUrl", "nutzungsbedingungen")
    |> put_legal_url("privacyPolicyUrl", "datenschutzerklaerung")
  end

  # The configured description says what is true of vutuv on **every**
  # installation (open source, no tracking, no third-party cookies). Where the
  # servers stand is not: it is a promise only the operator can make, so it is
  # appended from `:data_location` and drops out entirely for an operator who
  # cleared it — the same split the start page's "Your data" cards make, and
  # `VutuvWeb.PageHTML.data_location/0` is the one place that decides whether
  # the claim was made at all.
  defp node_description do
    description = Application.fetch_env!(:vutuv, :node_description)

    case PageHTML.data_location() do
      nil -> description
      place -> description <> " Hosted on our own hardware in #{place}."
    end
  end

  defp locales, do: Languages.site_locales()

  defp put_legal_url(metadata, key, slug) do
    case Legal.get_page(slug) do
      %LegalPage{body: body} when is_binary(body) ->
        if String.trim(body) == "",
          do: metadata,
          else: Map.put(metadata, key, Endpoint.url() <> "/" <> slug)

      _unwritten ->
        metadata
    end
  end

  @doc """
  The figures behind `usage`: `%{users: %{total:, active_month:,
  active_halfyear:}, local_posts:, local_comments:}`. Three aggregates, all of
  them exact — see the module doc for what each one means and why. `document/1`
  is what renames them to the schema's spelling.
  """
  def usage do
    {posts, comments} = post_counts()

    %{
      users: Map.put(active_users(), :total, Accounts.count_users()),
      local_posts: posts,
      local_comments: comments
    }
  end

  # 2.1 adds the two pointers at the source; 2.0 has no place for them.
  defp software("2.1") do
    Map.merge(software("2.0"), %{"repository" => SourceRepo.url(), "homepage" => @homepage})
  end

  defp software(_version) do
    %{"name" => @software_name, "version" => BuildInfo.version()}
  end

  # Both windows in one round trip. `count(DISTINCT user_id)` because the
  # figure counts people, not devices: a member signed in on a phone and a
  # laptop is one active member. Joined to `users` with the same predicate
  # `Accounts.count_users/0` uses, so `activeMonth <= activeHalfyear <= total`
  # holds by construction rather than by luck.
  defp active_users do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    month = DateTime.add(now, -@month_days, :day)
    halfyear = DateTime.add(now, -@halfyear_days, :day)

    Repo.one(
      from(s in UserSession,
        join: u in User,
        on: u.id == s.user_id,
        where: ModerationQuery.account_confirmed_row(u),
        where: s.last_seen_at > ^halfyear,
        select: %{
          active_halfyear: fragment("count(DISTINCT ?)", s.user_id),
          active_month:
            fragment("count(DISTINCT ?) FILTER (WHERE ? > ?)", s.user_id, s.last_seen_at, ^month)
        }
      )
    )
  end

  # The publicly visible posts, split into originals and replies in one pass.
  #
  # Joined rather than asked with two `EXISTS` subqueries in the SELECT list:
  # a predicate inside `filter(count(...), …)` cannot be turned into a semi-join,
  # so Postgres ran both subplans once per visible post. `post_replies` has a
  # unique index on `post_id`, so the left join answers at most one row per post
  # and `count(r.post_id)` is the reply tally exactly.
  defp post_counts do
    %{posts: posts, comments: comments} =
      Post
      |> Posts.scope_visible(nil)
      |> join(:left, [p], r in "post_replies", on: r.post_id == p.id)
      |> select([p, r], %{posts: count(p.id) - count(r.post_id), comments: count(r.post_id)})
      |> Repo.one()

    {posts, comments}
  end
end
