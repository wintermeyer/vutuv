defmodule Vutuv.Profiles.LinkVerification do
  @moduledoc """
  "This link is my webpage" verification for a member's profile links. A member
  proves a `Vutuv.Profiles.Url` is really their page with one of three methods
  (`Vutuv.WebVerification`) and it earns a small verified mark:

    * `rel_me` (default) — the page links back to the member's profile with
      `rel="me"`. Works on any page the member can edit (a blog, a `github.io`
      page, a hosted portfolio), even shared hosting.
    * `dns` / `well_known` — the organization-style domain proofs, for a member who
      controls the whole host.

  Verification is per-link and independent (no uniqueness / anti-squatting
  constraint: two members may each prove the same shared host by their own
  proof). Verified links are re-checked periodically with a grace window before
  the mark drops, mirroring `Vutuv.Organizations` domain re-checks.

  Gated by `:verify_user_links` (default on). Off = disabled on this
  installation (no outbound calls); intranet-safe.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo
  alias Vutuv.WebVerification

  # The personal-webpage verification scheme, deliberately distinct from the
  # `vutuv-organization-verify=` scheme organizations use (see
  # `Vutuv.Organizations.Verification`), so a link proof never doubles as an organization
  # proof on the same host.
  @dns_prefix "vutuv-verify="
  @well_known_path "/.well-known/vutuv-verify.txt"

  @grace_days 7
  # A verified webpage proof rarely changes, so re-check weekly; the hourly
  # sweeper tick just spreads the checks out rather than bursting them.
  @recheck_interval_hours 24 * 7

  @doc "Whether link verification is enabled for this installation."
  def enabled?, do: Application.get_env(:vutuv, :verify_user_links, true)

  @doc """
  The canonical profile URL(s) a `rel="me"` back-link must point at. Derived
  from the endpoint host (installability-safe — never a literal vutuv.de).
  """
  def profile_urls(%User{username: username}) do
    [VutuvWeb.Endpoint.url() <> "/" <> username]
  end

  @doc """
  Ensures the link carries a `verification_token` (needed for the DNS /
  well-known instructions; rel=me ignores it). Returns the (possibly updated)
  link.
  """
  def ensure_token(%Url{verification_token: token} = url) when is_binary(token), do: url

  def ensure_token(%Url{} = url) do
    {:ok, url} =
      url
      |> Url.verification_changeset(%{verification_token: WebVerification.gen_token()})
      |> Repo.update()

    url
  end

  @doc "The exact DNS TXT record value the member must publish."
  def dns_txt_value(%Url{verification_token: token}) when is_binary(token),
    do: WebVerification.dns_txt_value(@dns_prefix, token)

  @doc """
  The CNAME-safe alternate name (`_vutuv.<host>`) the DNS TXT record may also
  live at, for a link whose host is itself a CNAME.
  """
  def dns_challenge_name(%Url{value: value}),
    do: WebVerification.dns_challenge_name(host(value))

  @doc "The well-known URL fetched for the `well_known` method."
  def well_known_url(%Url{value: value}),
    do: WebVerification.well_known_url(host(value), @well_known_path)

  @doc "The exact content the well-known file must serve (the token)."
  def well_known_content(%Url{verification_token: token}), do: token

  @doc """
  Verifies that `url` is `user`'s webpage via `method` and **says what it saw**
  (issue #1466). On success stamps the method and timestamps and returns
  `{:ok, url}`; otherwise `{:error, report}` naming what was queried, what was
  wanted and what was actually there.

  A flat "we could not find the proof yet, please try again" leaves a member
  re-reading their own zone file or page source with nothing to compare against,
  which is what #1466 described doing for the organization half of this. The
  report is the same shape the organization verification panel shows
  (`Vutuv.Organizations.check_domain/2`), plus `disabled?` for the one case that
  is not about the page at all: link verification is off on this installation.

  It deliberately does **not** stamp `last_checked_at`. That column drives the
  weekly re-check sweeper's schedule, so writing it here would let a member push
  their own link's re-check out by pressing a button.
  """
  def check(%Url{} = url, %User{} = user, method) when method in ~w(rel_me dns well_known) do
    if enabled?() do
      # Minting the token here is what keeps the report renderable: without one
      # the two domain methods fall through to `run_check/3`'s last clause,
      # whose report carries none of the fields the panel prints. That is a
      # KeyError in the view rather than a message, so the shape is guaranteed
      # at the door instead of guarded at every reader.
      url = ensure_token(url)

      case run_check(url, user, method) do
        {:ok, _report} -> mark_verified(url, method)
        {:error, report} -> {:error, Map.put(report, :disabled?, false)}
      end
    else
      {:error, %{method: method, disabled?: true}}
    end
  end

  # The single proof dispatch: `check/3` shows the report, `recheck/1` only needs
  # the verdict. Deriving the boolean from the report rather than calling the
  # `*_verified?` twins keeps the two from ever disagreeing about the same page.
  defp run_check(%Url{} = url, %User{} = user, "rel_me"),
    do: WebVerification.rel_me_check(url.value, profile_urls(user), req_options())

  defp run_check(%Url{verification_token: token, value: value}, _user, "dns")
       when is_binary(token),
       do: WebVerification.dns_check(host(value), @dns_prefix, token, dns_resolver())

  defp run_check(%Url{verification_token: token, value: value}, _user, "well_known")
       when is_binary(token),
       do: WebVerification.well_known_check(host(value), @well_known_path, token, req_options())

  # A link with no token yet cannot carry a DNS / well-known proof at all. Only
  # `proof_present?/2` can reach this — `check/3` mints the token first — so the
  # verdict is all this has to answer; it is never rendered.
  defp run_check(_url, _user, method), do: {:error, %{method: method, found: nil}}

  defp proof_present?(%Url{} = url, %User{} = user, method),
    do: match?({:ok, _report}, run_check(url, user, method))

  defp mark_verified(%Url{} = url, method) do
    now = now()

    url
    |> Url.verification_changeset(%{
      verification_method: method,
      verified_at: now,
      last_checked_at: now,
      grace_deadline_at: nil
    })
    |> Repo.update()
  end

  # --- periodic re-check ------------------------------------------------------

  @doc "Verified links whose last check is older than the interval."
  def links_due_for_recheck(now \\ NaiveDateTime.utc_now()) do
    cutoff = NaiveDateTime.add(now, -@recheck_interval_hours * 3600)

    Repo.all(
      from(u in Url,
        where:
          not is_nil(u.verified_at) and
            (is_nil(u.last_checked_at) or u.last_checked_at < ^cutoff),
        preload: [:user]
      )
    )
  end

  @doc """
  Re-checks all due verified links (called by the sweeper). No-op when link
  verification is disabled. Returns the count of links that lost their verified
  mark this run.
  """
  def recheck_due_links do
    if enabled?() do
      # Each check does one blocking DNS / HTTP call (no DB connection held
      # during it), so run them with bounded concurrency instead of summing
      # every link's network latency serially.
      links_due_for_recheck()
      |> Task.async_stream(&recheck/1, max_concurrency: 10, ordered: false, timeout: :infinity)
      |> Enum.count(fn {:ok, outcome} -> outcome == :demoted end)
    else
      0
    end
  end

  @doc """
  Re-checks one verified link. On success refreshes `last_checked_at` and clears
  any grace window; on failure starts a grace window, waits it out, then drops
  the verified mark. Returns an outcome atom.
  """
  def recheck(%Url{user: %User{} = user} = url) do
    now = now()

    if proof_present?(url, user, url.verification_method) do
      url
      |> Url.verification_changeset(%{last_checked_at: now, grace_deadline_at: nil})
      |> Repo.update()

      :ok
    else
      handle_recheck_failure(url, now)
    end
  end

  defp handle_recheck_failure(%Url{} = url, now) do
    cond do
      is_nil(url.grace_deadline_at) ->
        deadline = NaiveDateTime.add(now, @grace_days * 86_400)

        url
        |> Url.verification_changeset(%{last_checked_at: now, grace_deadline_at: deadline})
        |> Repo.update()

        :grace_started

      NaiveDateTime.compare(now, url.grace_deadline_at) == :lt ->
        url |> Url.verification_changeset(%{last_checked_at: now}) |> Repo.update()
        :in_grace

      true ->
        url
        |> Url.verification_changeset(%{
          verification_method: nil,
          verified_at: nil,
          last_checked_at: now,
          grace_deadline_at: nil
        })
        |> Repo.update()

        :demoted
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp host(value), do: value |> to_string() |> URI.parse() |> Map.get(:host) |> to_string()

  defp dns_resolver do
    Application.get_env(:vutuv, :user_links_dns_resolver, &WebVerification.default_txt_lookup/1)
  end

  defp req_options do
    Application.get_env(:vutuv, :user_links_req_options, [])
  end

  defp now, do: NaiveDateTime.utc_now(:second)
end
