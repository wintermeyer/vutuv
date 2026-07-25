defmodule Vutuv.AccountEventsTest do
  @moduledoc """
  The account-activity log (issue #1087). The security-shaped tests are the
  point of this file: the whitelist, the email masking, and the audit over the
  registry that fails the build if a kind ever declares a credential-looking
  detail key.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.AccountEvents
  alias Vutuv.AccountEvents.AccountEvent
  alias Vutuv.Repo

  describe "record/3" do
    test "stores who, what, when, from where and how it was confirmed" do
      user = insert(:user)

      :ok =
        AccountEvents.record(user, "signed_in",
          factor: "passkey",
          ip: "203.0.113.4",
          device: "Chrome on macOS"
        )

      assert [event] = Repo.all(AccountEvent)
      assert event.user_id == user.id
      assert event.kind == "signed_in"
      assert event.factor == "passkey"
      assert event.ip_address == "203.0.113.4"
      assert event.device == "Chrome on macOS"
      assert event.actor_user_id == nil
      assert %DateTime{} = event.inserted_at
    end

    test "keeps microsecond resolution, so two events in the same second still have an order" do
      user = insert(:user)
      :ok = AccountEvents.record(user, "signed_in")
      :ok = AccountEvents.record(user, "signed_out")

      [first, second] = Repo.all(from(e in AccountEvent, order_by: [asc: e.inserted_at]))

      assert first.kind == "signed_in"
      assert second.kind == "signed_out"
      assert DateTime.compare(first.inserted_at, second.inserted_at) in [:lt, :eq]
      # Not truncated to the second: the whole point of the column's precision.
      assert first.inserted_at.microsecond |> elem(1) > 0
    end

    test "records the acting admin when somebody else did it" do
      member = insert(:user)
      admin = insert(:user, admin?: true)

      :ok = AccountEvents.record(member, "account_frozen", factor: "admin", actor: admin)

      assert [event] = Repo.all(AccountEvent)
      assert event.user_id == member.id
      assert event.actor_user_id == admin.id
    end

    test "takes the IP and a COARSE device summary from a conn, never the raw User-Agent" do
      user = insert(:user)

      ua =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("user-agent", ua)
        |> Map.put(:remote_ip, {203, 0, 113, 9})

      :ok = AccountEvents.record(user, "signed_in", conn: conn)

      assert [event] = Repo.all(AccountEvent)
      assert event.ip_address == "203.0.113.9"
      assert event.device == "Chrome on macOS"
      refute event.device =~ "AppleWebKit"
    end

    test "an undeclared kind is refused (and never raises on the caller)" do
      user = insert(:user)

      assert :ok = AccountEvents.record(user, "password_leaked_lol")
      assert Repo.all(AccountEvent) == []
    end

    test "an undeclared detail key is refused, so nothing unreviewed can reach the table" do
      user = insert(:user)

      assert :ok = AccountEvents.record(user, "signed_in", details: %{pin: "123456"})
      assert Repo.all(AccountEvent) == []
    end

    test "a nil member is a no-op rather than a crash" do
      assert :ok = AccountEvents.record(nil, "signed_out")
      assert Repo.all(AccountEvent) == []
    end
  end

  describe "the vocabulary is the security boundary" do
    test "no declared detail key reads like a credential" do
      forbidden = ~w(pin token secret password code_value key hash credential otp)

      for {kind, keys} <- AccountEvents.registry(), key <- keys, word <- forbidden do
        refute String.contains?(key, word),
               "#{kind} declares a detail key #{inspect(key)} containing #{inspect(word)}; " <>
                 "the activity log must never hold credential material"
      end
    end

    test "every declared kind has a member-readable label" do
      for kind <- AccountEvents.kinds() do
        assert VutuvWeb.AccountEventText.event_label(kind) != kind,
               "#{kind} has no label in VutuvWeb.AccountEventText"
      end
    end
  end

  describe "mask_email/1" do
    test "keeps an address recognizable without keeping it usable" do
      assert AccountEvents.mask_email("anna@example.com") == "an***@example.com"
      assert AccountEvents.mask_email("jo@example.com") == "j***@example.com"
      assert AccountEvents.mask_email("not-an-address") == "***"
      assert AccountEvents.mask_email(nil) == nil
    end
  end

  describe "reading the member's own log" do
    setup do
      user = insert(:user)
      other = insert(:user)

      :ok = AccountEvents.record(user, "signed_in", factor: "pin", ip: "203.0.113.1")
      :ok = AccountEvents.record(user, "passkey_added", details: %{nickname: "Work laptop"})
      :ok = AccountEvents.record(other, "signed_in", ip: "198.51.100.7")

      %{user: user, other: other}
    end

    test "only the member's own events", %{user: user} do
      assert AccountEvents.count(user, AccountEvents.filters(%{})) == 2
      ips = user |> AccountEvents.page(AccountEvents.filters(%{})) |> Enum.map(& &1.ip_address)
      refute "198.51.100.7" in ips
    end

    test "newest first by default", %{user: user} do
      assert [%{kind: "passkey_added"}, %{kind: "signed_in"}] =
               AccountEvents.page(user, AccountEvents.filters(%{}))
    end

    test "sorts by time the other way round", %{user: user} do
      filters = AccountEvents.filters(%{"sort" => "time", "dir" => "asc"})
      assert [%{kind: "signed_in"} | _] = AccountEvents.page(user, filters)
    end

    test "filters by kind", %{user: user} do
      filters = AccountEvents.filters(%{"kind" => "passkey_added"})
      assert [%{kind: "passkey_added"}] = AccountEvents.page(user, filters)
      assert AccountEvents.count(user, filters) == 1
    end

    test "an unknown kind param is ignored rather than returning nothing", %{user: user} do
      filters = AccountEvents.filters(%{"kind" => "nonsense"})
      assert filters.kind == nil
      assert AccountEvents.count(user, filters) == 2
    end

    test "searches the IP, the factor and the details", %{user: user} do
      assert [%{kind: "signed_in"}] =
               AccountEvents.page(user, AccountEvents.filters(%{"q" => "203.0.113"}))

      assert [%{kind: "signed_in"}] =
               AccountEvents.page(user, AccountEvents.filters(%{"q" => "pin"}))

      assert [%{kind: "passkey_added"}] =
               AccountEvents.page(user, AccountEvents.filters(%{"q" => "Work laptop"}))
    end

    test "lists only the kinds that actually occur", %{user: user} do
      assert Enum.sort(AccountEvents.kinds_present(user)) == ~w(passkey_added signed_in)
    end

    test "pages", %{user: user} do
      filters = AccountEvents.filters(%{})
      assert [_one] = AccountEvents.page(user, filters, %{"page" => 2}, per_page: 1)
    end
  end

  describe "the admin's cross-member view" do
    setup do
      anna = insert(:user, username: "activity-anna", first_name: "Anna")
      bert = insert(:user, username: "activity-bert", first_name: "Bert")
      insert(:email, user: anna, value: "anna-activity@example.com")

      :ok = AccountEvents.record(anna, "signed_in")
      :ok = AccountEvents.record(bert, "signed_out")

      %{anna: anna, bert: bert}
    end

    test "sees every member" do
      assert AccountEvents.admin_count(AccountEvents.admin_filters(%{})) == 2
    end

    test "filters by @handle" do
      filters = AccountEvents.admin_filters(%{"member" => "activity-anna"})
      assert [event] = AccountEvents.admin_page(filters)
      assert event.user.username == "activity-anna"
    end

    test "filters by name and by email address", %{anna: anna} do
      by_name = AccountEvents.admin_page(AccountEvents.admin_filters(%{"member" => "Anna"}))
      assert [%{user_id: id}] = by_name
      assert id == anna.id

      by_email =
        AccountEvents.admin_page(AccountEvents.admin_filters(%{"member" => "anna-activity@"}))

      assert [%{user_id: ^id}] = by_email
    end

    test "sorts by member, filtered, without joining users twice" do
      filters = AccountEvents.admin_filters(%{"member" => "activity-", "sort" => "member"})
      assert [first, second] = AccountEvents.admin_page(filters)
      assert first.user.username == "activity-anna"
      assert second.user.username == "activity-bert"
    end
  end

  describe "retention" do
    test "deletes events past the retention window and keeps the rest" do
      user = insert(:user)
      :ok = AccountEvents.record(user, "signed_in")

      old =
        Repo.insert!(%AccountEvent{
          user_id: user.id,
          kind: "signed_out",
          details: %{},
          inserted_at: DateTime.add(DateTime.utc_now(), -400 * 86_400, :second)
        })

      assert AccountEvents.delete_expired() == 1
      assert [kept] = Repo.all(AccountEvent)
      assert kept.kind == "signed_in"
      refute Repo.get(AccountEvent, old.id)
    end
  end

  describe "the log is personal data" do
    test "rides along in the GDPR export" do
      user = insert(:user)
      :ok = AccountEvents.record(user, "signed_in", factor: "pin", ip: "203.0.113.1")

      assert %{account_events: [entry]} = Vutuv.Export.build(user)
      assert entry.kind == "signed_in"
      assert entry.factor == "pin"
      assert entry.by_someone_else == false
    end

    test "is deleted with the account" do
      user = insert(:user)
      :ok = AccountEvents.record(user, "signed_in")

      {:ok, _} = Vutuv.Accounts.delete_user(user)
      assert Repo.all(AccountEvent) == []
    end

    test "an acting admin's deletion nils the actor but keeps the member's entry" do
      member = insert(:user)
      admin = insert(:user, admin?: true)
      :ok = AccountEvents.record(member, "account_frozen", factor: "admin", actor: admin)

      {:ok, _} = Vutuv.Accounts.delete_user(admin)

      assert [event] = Repo.all(AccountEvent)
      assert event.user_id == member.id
      assert event.actor_user_id == nil
    end
  end
end
