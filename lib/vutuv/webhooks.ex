defmodule Vutuv.Webhooks do
  @moduledoc """
  Webhooks: signed event deliveries to registered apps.

  An app subscribes (per event, HTTPS endpoint, signing secret); when an
  event happens for a member, `emit/3` queues one delivery per
  subscription whose app holds an **active grant from that member
  covering the event's scope** — an app only ever hears about members who
  authorized it, and only within the permissions they granted. Payloads
  are thin envelopes (ids and slugs, never content bodies), so message
  text and post content never sit in third-party logs; the app fetches
  details through the scoped API.

  Delivery is a DB-backed queue (`Vutuv.Webhooks.Delivery`) drained by
  `Vutuv.Webhooks.Deliverer`: HTTPS POST via `Req`, HMAC-SHA256 signature
  in `X-Vutuv-Signature`, exponential backoff on failure, and a
  subscription that only ever fails gets disabled after 30 consecutive
  failures (days of retries) — visible to the developer on the app page,
  where it can be re-enabled.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.{App, Grant}
  alias Vutuv.Repo
  alias Vutuv.Webhooks.{Deliverer, Delivery, Subscription}

  @secret_prefix "vutuv_whsec_"

  # event => the scope a member must have granted the app for it to hear
  # about that member's events. "ping" is the test event (no grant needed —
  # it carries nothing and goes only where the developer points it).
  @events %{
    "follower.created" => "social:read",
    # Fired when a follow-back completes a mutual follow (the pair is now
    # vernetzt). Replaced the old connection.requested/accepted pair, which
    # belonged to the removed request/accept flow.
    "connection.created" => "social:read",
    "endorsement.created" => "social:read",
    "post.liked" => "posts:read",
    "post.replied" => "posts:read",
    "message.created" => "messages:read"
  }

  @max_attempts 8
  @max_consecutive_failures 30

  def events, do: Map.keys(@events)
  def required_scope(event), do: Map.fetch!(@events, event)
  def max_attempts, do: @max_attempts

  # ── Subscriptions (managed from the developer app page) ──

  @doc "Creates a subscription for `app`. Returns `{:ok, subscription, secret}` — the secret is shown once."
  def create_subscription(%App{} = app, attrs) do
    secret = @secret_prefix <> ApiAuth.random_token()

    changeset = Subscription.changeset(%Subscription{app_id: app.id, secret: secret}, attrs)
    with {:ok, subscription} <- Repo.insert(changeset), do: {:ok, subscription, secret}
  end

  def change_subscription(%Subscription{} = subscription, attrs \\ %{}) do
    Subscription.changeset(subscription, attrs)
  end

  def list_subscriptions(%App{} = app) do
    Repo.all(from(s in Subscription, where: s.app_id == ^app.id, order_by: [desc: s.id]))
  end

  def get_subscription(%App{} = app, id) do
    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil -> nil
      uuid -> Repo.get_by(Subscription, id: uuid, app_id: app.id)
    end
  end

  def delete_subscription!(%Subscription{} = subscription), do: Repo.delete!(subscription)

  @doc "Re-enables a disabled subscription (the developer fixed their endpoint)."
  def reactivate!(%Subscription{} = subscription) do
    subscription
    |> Ecto.Changeset.change(active?: true, disabled_reason: nil, consecutive_failures: 0)
    |> Repo.update!()
  end

  # ── Emission (called from the Vutuv.Activity / Vutuv.Chat chokepoints) ──

  @doc """
  Queues the event for every subscription whose app the member authorized
  with the event's scope. `member` is the user the event happened *to*
  (whose grant authorizes the delivery). Cheap when nobody subscribed:
  one indexed existence check.
  """
  # No guard on member_id: it is only dereferenced when subscriptions
  # exist, so unit tests with bare fixture ids pass through the fast path.
  def emit(member_id, event, data) when is_map_key(@events, event) do
    if subscriptions_exist?(event) do
      do_emit(member_id, event, data)
    end

    :ok
  end

  defp subscriptions_exist?(event) do
    Repo.exists?(from(s in Subscription, where: s.active? and ^event in s.events))
  end

  defp do_emit(member_id, event, data) do
    scope = required_scope(event)

    subscription_ids =
      Repo.all(
        from(s in Subscription,
          join: a in App,
          on: a.id == s.app_id,
          join: g in Grant,
          on: g.app_id == a.id,
          where: s.active? and ^event in s.events,
          where: is_nil(a.suspended_at),
          where: g.user_id == ^member_id and is_nil(g.revoked_at) and ^scope in g.scopes,
          select: s.id,
          distinct: true
        )
      )

    # Build the envelope (a slug lookup) only when there is a recipient — most
    # emits match no grant-qualified subscription, and `queue_all([])` would
    # just throw the envelope away.
    if subscription_ids == [] do
      :ok
    else
      queue_all(subscription_ids, event, envelope(member_id, event, data))
    end
  end

  defp envelope(member_id, event, data) do
    # Only the slug is needed for the thin envelope, not the wide user row.
    member_slug = Repo.one!(from(u in User, where: u.id == ^member_id, select: u.username))

    %{
      "event" => event,
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now(:second)),
      "member" => member_slug,
      "data" => data
    }
  end

  defp queue_all(subscription_ids, event, payload) do
    now = DateTime.utc_now(:second)
    naive_now = NaiveDateTime.utc_now(:second)

    rows =
      Enum.map(subscription_ids, fn subscription_id ->
        %{
          id: Vutuv.UUIDv7.generate(),
          subscription_id: subscription_id,
          event: event,
          payload: payload,
          next_attempt_at: now,
          inserted_at: naive_now,
          updated_at: naive_now
        }
      end)

    Repo.insert_all(Delivery, rows)
    Deliverer.nudge()
    :ok
  end

  @doc "Queues a test delivery for one subscription, grant checks skipped (it carries nothing)."
  def ping(%Subscription{} = subscription) do
    now = DateTime.utc_now(:second)

    Repo.insert!(%Delivery{
      subscription_id: subscription.id,
      event: "ping",
      payload: %{
        "event" => "ping",
        "occurred_at" => DateTime.to_iso8601(now),
        "data" => %{}
      },
      next_attempt_at: now
    })

    Deliverer.nudge()
    :ok
  end

  # ── Delivery (the Deliverer's work loop; also called directly by tests) ──

  @doc """
  Sends every due delivery (due, not exhausted, subscription active).
  Returns the number of rows attempted.
  """
  def deliver_due do
    now = DateTime.utc_now(:second)

    due =
      Repo.all(
        from(d in Delivery,
          join: s in assoc(d, :subscription),
          where: is_nil(d.delivered_at) and d.attempts < @max_attempts,
          where: d.next_attempt_at <= ^now,
          where: s.active?,
          preload: [subscription: s],
          limit: 100
        )
      )

    due
    |> Task.async_stream(&attempt/1, max_concurrency: 5, timeout: 30_000, on_timeout: :kill_task)
    |> Stream.run()

    length(due)
  end

  @doc false
  def attempt(%Delivery{subscription: %Subscription{} = subscription} = delivery) do
    # Defeat DNS rebinding at delivery time: the literal-IP gate runs when the
    # subscription is created, but a public hostname can be re-pointed at an
    # internal address afterwards (issue #775). Resolve now and refuse to POST
    # to our own network. `redirect: false` already blocks the 30x variant.
    if Vutuv.Ssrf.resolves_to_internal?(URI.parse(subscription.url).host) do
      fail(delivery, nil, "blocked: URL resolves to an internal address")
    else
      do_attempt(delivery, subscription)
    end
  end

  defp do_attempt(delivery, subscription) do
    body = Jason.encode!(delivery.payload)

    headers = [
      {"content-type", "application/json"},
      {"user-agent", "vutuv-webhooks/1.0"},
      {"x-vutuv-event", delivery.event},
      {"x-vutuv-delivery", delivery.id},
      {"x-vutuv-signature", "sha256=" <> sign(body, subscription.secret)}
    ]

    options =
      Keyword.merge(
        [
          url: subscription.url,
          body: body,
          headers: headers,
          receive_timeout: 10_000,
          retry: false,
          # Never chase redirects: an allowed https endpoint that 30x-redirects
          # to an internal/loopback/metadata host would otherwise turn delivery
          # into an SSRF primitive (Req follows up to 10 redirects by default).
          redirect: false
        ],
        Application.get_env(:vutuv, :webhook_req_options, [])
      )

    case Req.post(options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        succeed(delivery, status)

      {:ok, %Req.Response{status: status}} ->
        fail(delivery, status, "HTTP #{status}")

      {:error, exception} ->
        fail(delivery, nil, Exception.message(exception))
    end
  end

  @doc "The signature scheme: hex HMAC-SHA256 over the raw body."
  def sign(body, secret) do
    :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp succeed(delivery, status) do
    now = DateTime.utc_now(:second)

    delivery
    |> Ecto.Changeset.change(
      delivered_at: now,
      attempts: delivery.attempts + 1,
      last_status: status,
      last_error: nil
    )
    |> Repo.update!()

    reset_failures(delivery.subscription)
    :ok
  end

  defp fail(delivery, status, error) do
    attempts = delivery.attempts + 1

    delivery
    |> Ecto.Changeset.change(
      attempts: attempts,
      next_attempt_at: backoff_at(attempts),
      last_status: status,
      last_error: String.slice(error || "", 0, 250)
    )
    |> Repo.update!()

    count_failure(delivery.subscription)
    :error
  end

  # 2, 4, 8, … minutes — attempt 8 retries after ~4 hours; with the
  # consecutive-failures budget a permanently dead endpoint is disabled
  # after a few days of events.
  defp backoff_at(attempts) do
    DateTime.add(DateTime.utc_now(:second), trunc(:math.pow(2, attempts)) * 60)
  end

  # Both counters update atomically in the database: deliveries of the same
  # subscription run concurrently (and each carries its own preloaded copy of
  # the subscription), so a struct read-modify-write would lose increments.

  defp reset_failures(subscription) do
    from(s in Subscription, where: s.id == ^subscription.id and s.consecutive_failures != 0)
    |> Repo.update_all(set: [consecutive_failures: 0])

    :ok
  end

  defp count_failure(subscription) do
    {1, [failures]} =
      from(s in Subscription, where: s.id == ^subscription.id, select: s.consecutive_failures)
      |> Repo.update_all(inc: [consecutive_failures: 1])

    if failures >= @max_consecutive_failures do
      from(s in Subscription, where: s.id == ^subscription.id and s.active?)
      |> Repo.update_all(
        set: [
          active?: false,
          disabled_reason: "disabled after #{failures} consecutive delivery failures"
        ]
      )
    end

    :ok
  end
end
