defmodule Vutuv.Profiles.VerifiedLinks do
  @moduledoc """
  Does a URL written in a post point at a page its author has **proved** is
  theirs (`Vutuv.Profiles.LinkVerification`)? Issue #1246.

  The mark this answer drives is a trust signal, so it must never claim more
  than the proof states. `Vutuv.Profiles.Url` records which method proved a
  link, and each method proves a different scope:

    * `dns` / `well_known` — the member controls the whole host, so **any**
      link on that host is theirs;
    * `rel_me` whose proven URL is the host root (`/` or no path) — a `rel="me"`
      back-link from the front page is effectively the same host claim;
    * `rel_me` on a deeper path — the back-link sits on that one page, so
      **only that exact URL** is proved.

  The last tier is the reason this module exists. A member on shared hosting
  proves `example.com/~alice`; matching on the host alone would put their
  checkmark on `example.com/~bob`, who is a different person, and on
  `example.com/~alice/foo`, which nobody proved.

  Matching is always against **one author's own** links: verification carries
  no uniqueness constraint (two members may each prove the same shared host by
  their own proof), so a global lookup would attribute a stranger's proof.

  Comparison follows the "recognising one of our own URLs" rule: parse with
  `URI.parse/1`, never a string prefix. Hosts compare case-insensitively with
  a leading `www.` stripped on both sides (the same reading
  `Vutuv.Fediverse.local_host?/1` uses — serving a site at both the apex and
  its `www.` alias is the oldest convention on the web). `http` and `https`
  are the same site, a trailing slash is not a different page, and the query
  and the fragment are ignored: a reader who pastes a link carrying
  `?utm_source=` is naming the same page. The **path** keeps its case, because
  a case-sensitive server really does serve `/~Alice` and `/~alice` as two
  different pages.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo

  # The proofs that speak for the whole host rather than for one page.
  @host_methods ~w(dns well_known)

  @doc """
  The verified links among a member's profile links, `[]` when the `urls`
  association was not loaded — a surface that forgot the preload marks
  nothing rather than raising or firing a query per post card.
  """
  def of(%{urls: urls}) when is_list(urls), do: Enum.filter(urls, &Url.verified?/1)
  def of(_owner), do: []

  @doc """
  A member's verified links: straight off the preloaded association where a
  caller already carries it (every post card does — see
  `Vutuv.Posts.post_preloads/0`), otherwise with one query.

  For the single-record surfaces that resolve the author separately from the
  post, above all the permalink's agent documents. Never call it inside a
  list: on a page of posts that is one query per card, which is exactly what
  the preload exists to avoid.
  """
  def load(%User{urls: urls} = user) when is_list(urls), do: of(user)

  def load(%User{id: user_id}) do
    Repo.all(
      from(u in Url,
        where: u.user_id == ^user_id and not is_nil(u.verified_at),
        order_by: u.id
      )
    )
  end

  @doc """
  The `Repo.preload/2` spec that loads exactly the links `of/1` would keep.

  One owner for the scope, because three surfaces load it and a fourth reads
  the result: the post preloads (`Vutuv.Posts.post_preloads/0`), the Mastodon
  adapter's account endpoints, and anything else that renders a member outside
  a post. Scoped in the query rather than filtered afterwards, so a member with
  fifty links still ships the handful they proved — and ordered, because an
  un-ordered multi-row preload comes back in whatever order Postgres likes (id
  order is creation order, ids being UUID v7).
  """
  def preload_spec do
    [urls: from(u in Url, where: not is_nil(u.verified_at), order_by: u.id)]
  end

  @doc """
  The link among `verified_links` that proves `url`, or `nil`.

  Pass only the **post author's** verified links (see the module doc).
  """
  def match(url, verified_links) when is_binary(url) and is_list(verified_links) do
    case normalize(url) do
      nil -> nil
      target -> Enum.find(verified_links, &covers?(&1, target))
    end
  end

  def match(_url, _verified_links), do: nil

  @doc """
  What a proof covers, as a word the machine-readable documents carry:
  `"host"` for a whole-host claim, `"page"` for a single proven URL.
  """
  def scope(%Url{} = link) do
    if host_claim?(link), do: "host", else: "page"
  end

  @doc """
  The proven address in the shortest honest form — the bare host for a
  whole-host claim, host + path for a single proven page. This is what the
  mark names, so it says exactly what was proved and nothing wider.
  """
  def address(%Url{} = link) do
    case normalize(link.value) do
      nil -> link.value
      {host, path} -> if host_claim?(link), do: host, else: join_address(host, path)
    end
  end

  defp join_address(host, "/"), do: host
  defp join_address(host, path), do: host <> path

  defp covers?(%Url{} = link, {host, path}) do
    with true <- Url.verified?(link),
         {^host, proven_path} <- normalize(link.value) do
      host_claim?(link) or proven_path == path
    else
      _no -> false
    end
  end

  # A whole-host claim: the two domain proofs always, a rel=me back-link only
  # when it sits at the host root.
  defp host_claim?(%Url{verification_method: method}) when method in @host_methods, do: true

  defp host_claim?(%Url{verification_method: "rel_me", value: value}),
    do: match?({_host, "/"}, normalize(value))

  defp host_claim?(_link), do: false

  # `{host, path}` for an http(s) URL, nil for anything else (a mailto:, a
  # root-relative path, an empty string): nothing that names no host can be
  # proved, so it can never match.
  defp normalize(value) when is_binary(value) do
    uri = URI.parse(String.trim(value))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      {canonical_host(uri.host), canonical_path(uri.path)}
    end
  end

  defp normalize(_value), do: nil

  defp canonical_host(host) do
    host |> String.downcase() |> String.trim_trailing(".") |> strip_www()
  end

  defp strip_www("www." <> rest), do: rest
  defp strip_www(host), do: host

  defp canonical_path(nil), do: "/"

  defp canonical_path(path) do
    # `trim_trailing/2` drops EVERY trailing slash, so a pathological "//"
    # would come back empty rather than as the root it names.
    case String.trim_trailing(path, "/") do
      "" -> "/"
      trimmed -> trimmed
    end
  end
end
