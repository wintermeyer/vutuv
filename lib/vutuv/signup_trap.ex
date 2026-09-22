defmodule Vutuv.SignupTrap do
  @moduledoc """
  Sign-ups that scripts create in bulk, recognised by what they type and then
  quietly not created.

  A registration one of the rules below recognises gets the ordinary PIN
  screen (`Vutuv.Accounts.pretend_registration/2`), but no account is written
  and no mail goes out. From the outside that looks like a real sign-up whose
  mail is slow, so the sender learns nothing to adapt to. What the form
  submitted is kept in `trapped_registrations` for the operator's weekly
  report, which is the material the next rule gets written from.

  **Adding a rule** takes an entry in `@rules` (its name and the label the
  report shows), a clause of `rule?/2` and a test beside the others in
  `test/vutuv/signup_trap_test.exs`. A rule only ever sees a form that would
  otherwise have created an account (`trap/3`): an invalid one is refused the
  ordinary way first, so the trap never changes what a typo looks like.

  **The weekly report** lists every entry that arrived before the last Monday,
  07:00 German time, and has not been reported yet (`run/2`). An hourly tick
  (`Vutuv.SignupTrap.Reporter`) asks that question, so a deploy or a crash on
  Monday morning delays the mail by an hour instead of losing it. Entries are
  deleted 14 days after they arrive, whatever became of the mail, which is the
  period the privacy policy states.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Changeset
  alias Vutuv.ApiAuth.UserAgent
  alias Vutuv.BerlinTime
  alias Vutuv.EmailDomain
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo
  alias Vutuv.SignupTrap.Entry

  # Each rule's name (stored with every entry it catches) and the label the
  # weekly report gives it.
  @rules [same_lowercase_name: "Vor- und Nachname gleich, kleiner Anfangsbuchstabe"]
  @labels Map.new(@rules, fn {rule, label} -> {Atom.to_string(rule), label} end)

  @retention_days 14
  # The report waits in the operator's inbox at the start of the week.
  @report_hour 7
  # Entries the mail lists one by one; its counts cover all of them.
  @listed 300

  # What one unauthenticated POST may leave behind in a row.
  @max_params 50
  @max_value 500
  @max_text 1_000

  # The form fields an entry keeps in columns of their own, so `params` does
  # not carry them a second time.
  @column_params ~w(first_name last_name tag_list emails.0.value)

  # ── Rules ──

  @doc """
  The name of the first rule the submitted `fields` match, or nil. `fields`
  holds `:first_name`, `:last_name`, `:email` and `:tag_list`.
  """
  def match(fields),
    do: Enum.find_value(@rules, fn {rule, _label} -> rule?(rule, fields) && rule end)

  # The bulk sign-ups of September 2026 typed one random lowercase word as both
  # first and last name ("ihclfjep ihclfjep"). A person whose first and last
  # name are the same word and who types it in lower case is rare enough that
  # the weekly report is where they would show up.
  defp rule?(:same_lowercase_name, %{first_name: name, last_name: name}) when is_binary(name),
    do: name =~ ~r/\A\p{Ll}\p{L}{3,}\z/u

  defp rule?(_rule, _fields), do: false

  @doc """
  How the weekly report names a stored rule. A rule removed from `@rules` keeps
  its bare name for the two weeks its entries outlive it.
  """
  def rule_label(rule), do: Map.get(@labels, rule, rule)

  @doc """
  Asked by `Vutuv.Accounts.register_user/3` before it writes anything: records
  an otherwise valid registration that matches a rule and answers
  `{:trapped, email}`, or `:ok` for everything else, invalid forms included.
  """
  def trap(%Plug.Conn{} = conn, %Changeset{valid?: true} = changeset, params) do
    fields = fields(changeset)

    case match(fields) do
      nil ->
        :ok

      rule ->
        record(conn, rule, fields, params)
        {:trapped, fields.email}
    end
  end

  def trap(_conn, %Changeset{}, _params), do: :ok

  defp fields(changeset) do
    %{
      first_name: trimmed(Changeset.get_field(changeset, :first_name)),
      last_name: trimmed(Changeset.get_field(changeset, :last_name)),
      email: changeset |> Changeset.get_assoc(:emails, :struct) |> first_address(),
      tag_list: Changeset.get_field(changeset, :tag_list)
    }
  end

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: nil

  defp first_address([%{value: value} | _]), do: value
  defp first_address(_none), do: nil

  # ── Recording ──

  @doc """
  Stores a trapped sign-up: `fields` as `trap/3` extracted them, the rest of
  the submitted form, and the request's IP address, user agent and
  `Accept-Language`.

  There is no changeset, because nothing here can be refused: the names and
  the address passed the registration changeset's own length checks, which sit
  inside these varchar(255) columns, and everything else is capped below.
  """
  def record(%Plug.Conn{} = conn, rule, fields, params) do
    Repo.insert!(%Entry{
      rule: Atom.to_string(rule),
      first_name: fields[:first_name],
      last_name: fields[:last_name],
      email: fields[:email],
      tag_list: cap(fields[:tag_list], @max_text),
      params: params |> flatten() |> Map.drop(@column_params),
      ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: UserAgent.capture(conn),
      accept_language:
        conn |> Plug.Conn.get_req_header("accept-language") |> List.first() |> cap(@max_text)
    })

    :ok
  end

  # Bytes first, graphemes second, like `Vutuv.SearchText.cap/1`: `String.slice/3`
  # alone walks the whole value to find its cut, and this POST is the sender's
  # to size.
  defp cap(value, max) when is_binary(value),
    do: value |> String.byte_slice(0, max * 4) |> String.slice(0, max)

  defp cap(_value, _max), do: nil

  # The form as one flat map of dotted keys (`emails.0.value`) to strings, at
  # most @max_params of them, each value cut at @max_value characters. The
  # sender picks the shape of this POST, so nothing about it is trusted to be
  # small.
  defp flatten(params) when is_map(params) do
    params
    |> pairs("")
    |> Enum.take(@max_params)
    |> Map.new(fn {key, value} -> {cap(key, 100), cap(value, @max_value)} end)
  end

  defp flatten(_params), do: %{}

  defp pairs(map, prefix) do
    Stream.flat_map(map, fn {key, value} ->
      key = prefix <> to_string(key)

      if is_map(value) and not is_struct(value),
        do: pairs(value, key <> "."),
        else: [{key, text(value)}]
    end)
  end

  defp text(value) when is_binary(value), do: value
  defp text(value), do: inspect(value, limit: 20, printable_limit: @max_value)

  # ── Weekly report ──

  @doc """
  The end of the last finished report week at `now`: the latest Monday, 07:00
  German time, that is not after `now`, as a UTC `DateTime`.
  """
  def report_boundary(%DateTime{} = now) do
    monday = now |> BerlinTime.date() |> Date.beginning_of_week()
    this_week = monday_at_report_hour(monday)

    if DateTime.before?(now, this_week),
      do: monday_at_report_hour(Date.add(monday, -7)),
      else: this_week
  end

  defp monday_at_report_hour(monday) do
    monday
    |> BerlinTime.trigger_instant(@report_hour * 60)
    |> DateTime.from_naive!("Etc/UTC")
  end

  @doc """
  One tick of the weekly clockwork at `now`: deletes the entries older than 14
  days, then mails every entry from before `report_boundary(now)` that no
  report has listed yet and stamps them `reported_at`. Returns how many entries
  it deleted and reported. `deliver` is `Emailer.deliver/1` outside tests.

  Safe to run every hour, and from both slots of a blue/green deploy at once:
  the entries stay locked while their mail goes out (`FOR UPDATE SKIP
  LOCKED`), so a second run finds nothing to send, and a failed or crashed
  delivery rolls the stamp back and leaves the week to the next tick. The
  price is that a mail that went out just before its process died is sent
  again: the operator reads one report twice, and none goes missing.
  """
  def run(now \\ DateTime.utc_now(:second), deliver \\ &Emailer.deliver/1) do
    deleted = delete_expired(now)
    %{deleted: deleted, reported: report(now, deliver)}
  end

  defp delete_expired(now) do
    cutoff = DateTime.add(now, -@retention_days, :day)
    {count, _} = Repo.delete_all(from(e in Entry, where: e.inserted_at < ^cutoff))
    count
  end

  defp report(now, deliver) do
    boundary = report_boundary(now)

    fn ->
      from(e in Entry,
        where: is_nil(e.reported_at) and e.inserted_at < ^boundary,
        select: map(e, [:id, :rule, :email, :ip_address]),
        lock: "FOR UPDATE SKIP LOCKED"
      )
      |> Repo.all()
      |> send_report(boundary, now, deliver)
    end
    |> Repo.transaction(timeout: :timer.minutes(2))
    |> case do
      {:ok, count} ->
        count

      {:error, reason} ->
        Logger.warning("Sign-up trap report not delivered: #{inspect(reason)}")
        0
    end
  end

  defp send_report([], _boundary, _now, _deliver), do: 0

  defp send_report(due, boundary, now, deliver) do
    ids = Enum.map(due, & &1.id)
    entries = from(e in Entry, where: e.id in ^ids)

    case due |> summary(entries, boundary) |> Emailer.signup_trap_report_email() |> deliver.() do
      {:ok, _receipt} ->
        :ok

      # The operator's own address was marked undeliverable. Asking again
      # every hour would not change that, so the week counts as reported.
      :suppressed ->
        Logger.warning("Sign-up trap report suppressed: the operator address bounces")

      {:error, reason} ->
        Repo.rollback(reason)
    end

    Repo.update_all(entries, set: [reported_at: now])
    length(due)
  end

  # What the mail says about the week: the totals over every entry, and the
  # first @listed entries one by one.
  defp summary(due, entries, boundary) do
    %{
      total: length(due),
      week_end: boundary,
      retention_days: @retention_days,
      by_rule: top(due, & &1.rule),
      domains: top(due, &EmailDomain.host_of(&1.email)),
      ips: top(due, & &1.ip_address),
      listed:
        Repo.all(from(e in entries, order_by: [asc: e.inserted_at, asc: e.id], limit: @listed))
    }
  end

  # The ten most frequent values, most frequent first.
  defp top(due, value) do
    due
    |> Enum.map(value)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {value, count} -> {-count, value} end)
    |> Enum.take(10)
  end
end
