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
  alias Vutuv.Moderation.Query, as: ModerationQuery
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Sessions.UserSession
  alias VutuvWeb.Endpoint

  require ModerationQuery

  # Newest first: a consumer picks the highest version it understands.
  @versions ["2.1", "2.0"]
  @rel_prefix "http://nodeinfo.diaspora.software/ns/schema/"

  # Under /system/ rather than at the `/nodeinfo` root word, which member
  # handles own. The specification does not fix the path — the link document
  # below is what says where the document lives, which is why Mastodon,
  # Pleroma and Misskey all serve it somewhere different.
  @path_prefix "/system/nodeinfo/"

  # Properties of the software, identical on every installation.
  @software_name "vutuv"
  @repository "https://github.com/wintermeyer/vutuv"
  @homepage "https://www.vutuv.de"

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
      "metadata" => %{
        "nodeName" => Application.fetch_env!(:vutuv, :node_name),
        "nodeDescription" => Application.fetch_env!(:vutuv, :node_description)
      }
    }
  end

  def document(_version), do: nil

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
    Map.merge(software("2.0"), %{"repository" => @repository, "homepage" => @homepage})
  end

  defp software(_version) do
    %{"name" => @software_name, "version" => to_string(Application.spec(:vutuv, :vsn))}
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
  defp post_counts do
    %{posts: posts, comments: comments} =
      Post
      |> Posts.scope_visible(nil)
      |> select([p], %{
        posts:
          filter(
            count(p.id),
            fragment("NOT EXISTS (SELECT 1 FROM post_replies r WHERE r.post_id = ?)", p.id)
          ),
        comments:
          filter(
            count(p.id),
            fragment("EXISTS (SELECT 1 FROM post_replies r WHERE r.post_id = ?)", p.id)
          )
      })
      |> Repo.one()

    {posts, comments}
  end
end
