defmodule Vutuv.SignupTrapTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.ApiAuth.UserAgent
  alias Vutuv.SignupTrap
  alias Vutuv.SignupTrap.Entry

  # Monday 2026-09-21, 07:00 German summer time.
  @boundary ~U[2026-09-21 05:00:00Z]

  defp insert_entry(attrs) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        %Entry{
          rule: "same_lowercase_name",
          first_name: "ihclfjep",
          last_name: "ihclfjep",
          email: "bot#{n}@trap.example",
          tag_list: "javascript, Linux, PHP",
          params: %{"gender" => "male"},
          ip_address: "203.0.113.7",
          user_agent: "BotBrowser/1.0",
          accept_language: "en-US",
          inserted_at: ~U[2026-09-18 12:00:00Z]
        },
        attrs
      )
    )
  end

  defp request do
    Plug.Test.conn(:post, "/new_registration")
    |> Map.put(:remote_ip, {203, 0, 113, 7})
    |> Plug.Conn.put_req_header("user-agent", "BotBrowser/1.0")
    |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
  end

  describe "match/1" do
    test "catches the same name twice when it starts lowercase and runs four letters or more" do
      for name <- ~w(ihclfjep dydylsqj pwded test müller) do
        assert SignupTrap.match(%{first_name: name, last_name: name}) == :same_lowercase_name
      end
    end

    test "lets everything else through" do
      for {first, last} <- [
            {"Anna", "Anna"},
            {"abc", "abc"},
            {"anna", "müller"},
            {"anna", "Anna"},
            {"jo-jo", "jo-jo"},
            {"anna", nil},
            {nil, nil}
          ] do
        refute SignupTrap.match(%{first_name: first, last_name: last}), "#{first} #{last}"
      end
    end
  end

  describe "record/4" do
    test "keeps what the form sent together with the address and the browser" do
      fields = %{
        first_name: "ihclfjep",
        last_name: "ihclfjep",
        email: "bot@trap.example",
        tag_list: "javascript, Linux, PHP"
      }

      params = %{
        "first_name" => "ihclfjep",
        "emails" => %{"0" => %{"value" => "bot@trap.example", "public?" => "true"}},
        "gender" => "male"
      }

      assert :ok = SignupTrap.record(request(), :same_lowercase_name, fields, params)

      assert [entry] = Repo.all(Entry)
      assert entry.rule == "same_lowercase_name"
      assert entry.email == "bot@trap.example"
      assert entry.tag_list == "javascript, Linux, PHP"
      assert entry.ip_address == "203.0.113.7"
      assert entry.user_agent == "BotBrowser/1.0"
      assert entry.accept_language == "de-DE,de"
      assert entry.params["gender"] == "male"
      assert entry.params["emails.0.public?"] == "true"
      # Kept in its own column, so not a second time among the rest.
      refute Map.has_key?(entry.params, "emails.0.value")
      assert entry.reported_at == nil
    end

    test "caps an oversized POST instead of refusing it" do
      params = Map.new(1..500, fn i -> {"field#{i}", String.duplicate("x", 5_000)} end)
      conn = Plug.Conn.put_req_header(request(), "user-agent", String.duplicate("u", 5_000))
      fields = %{first_name: "pwded", last_name: "pwded", email: "a@trap.example", tag_list: nil}

      assert :ok = SignupTrap.record(conn, :same_lowercase_name, fields, params)

      assert [entry] = Repo.all(Entry)
      assert map_size(entry.params) <= 50
      assert Enum.all?(Map.values(entry.params), &(String.length(&1) <= 500))
      assert String.length(entry.user_agent) == UserAgent.max_chars()
    end
  end

  describe "report_boundary/1" do
    test "a week ends on Monday at 07:00 German time" do
      assert SignupTrap.report_boundary(~U[2026-09-22 10:00:00Z]) == @boundary
      assert SignupTrap.report_boundary(@boundary) == @boundary
      assert SignupTrap.report_boundary(~U[2026-09-21 04:59:59Z]) == ~U[2026-09-14 05:00:00Z]
      # Winter time moves the same wall-clock hour one hour later in UTC.
      assert SignupTrap.report_boundary(~U[2026-11-03 00:00:00Z]) == ~U[2026-11-02 06:00:00Z]
    end
  end

  describe "run/2" do
    test "mails the finished week once and keeps the running one for next time" do
      last_week = insert_entry(%{})
      this_week = insert_entry(%{inserted_at: ~U[2026-09-21 05:30:00Z]})
      now = ~U[2026-09-21 06:00:00Z]

      assert %{reported: 1} = SignupTrap.run(now)

      assert_received {:email, email}

      assert email.to == [Vutuv.Operator.recipient()]
      assert email.text_body =~ last_week.email
      refute email.text_body =~ this_week.email

      assert Repo.reload(last_week).reported_at == now
      assert Repo.reload(this_week).reported_at == nil

      # Every later tick of the same week has nothing left to say.
      assert %{reported: 0} = SignupTrap.run(DateTime.add(now, 1, :hour))
      refute_received {:email, _}
    end

    test "a tick that comes days late still sends the week it missed" do
      entry = insert_entry(%{})

      assert %{reported: 1} = SignupTrap.run(~U[2026-09-24 13:00:00Z])
      assert_received {:email, email}
      assert email.text_body =~ entry.email
    end

    test "a delivery that dies leaves the week to the next tick" do
      entry = insert_entry(%{})
      now = ~U[2026-09-21 06:00:00Z]

      assert_raise RuntimeError, fn -> SignupTrap.run(now, fn _email -> raise "smtp down" end) end
      assert Repo.reload(entry).reported_at == nil

      assert %{reported: 0} = SignupTrap.run(now, fn _email -> {:error, :timeout} end)
      assert Repo.reload(entry).reported_at == nil

      assert %{reported: 1} = SignupTrap.run(DateTime.add(now, 1, :hour))
      assert_received {:email, email}
      assert email.text_body =~ entry.email
    end

    test "deletes every entry 14 days after it arrived, reported or not" do
      now = ~U[2026-09-22 10:00:00Z]
      expired = insert_entry(%{inserted_at: DateTime.add(now, -14 * 24 * 3600 - 1, :second)})
      unreported = insert_entry(%{inserted_at: DateTime.add(now, -15, :day)})
      kept = insert_entry(%{inserted_at: DateTime.add(now, -13, :day), reported_at: now})

      assert %{deleted: 2} = SignupTrap.run(now)

      refute Repo.reload(expired)
      refute Repo.reload(unreported)
      assert Repo.reload(kept)
    end

    test "sends nothing in a week nobody was caught" do
      assert %{reported: 0, deleted: 0} = SignupTrap.run(~U[2026-09-21 06:00:00Z])
      refute_received {:email, _}
    end
  end

  describe "the weekly mail" do
    test "shows everything each trapped sign-up sent" do
      entry =
        insert_entry(%{
          params: %{"gender" => "female", "noindex?" => "true"},
          user_agent: "Mozilla/5.0 (X11; Linux x86_64) BotKit/7"
        })

      SignupTrap.run(~U[2026-09-21 06:00:00Z])

      assert_received {:email, email}

      assert email.subject =~ "1 abgefangene Registrierung"

      for body <- [email.text_body, email.html_body] do
        assert body =~ "ihclfjep ihclfjep"
        assert body =~ entry.email
        assert body =~ "javascript, Linux, PHP"
        assert body =~ "203.0.113.7"
        assert body =~ "BotKit/7"
        assert body =~ "gender"
        assert body =~ "female"
        # Berlin wall-clock time, not UTC: 12:00 UTC is 14:00 in September.
        assert body =~ "18.09.2026 14:00"
      end

      assert email.html_body =~ "<table"
      assert email.html_body =~ "trap.example"
    end

    test "groups a large count the German way and lists only the first rows" do
      rows =
        for i <- 1..1_234 do
          %{
            id: Vutuv.UUIDv7.generate(),
            rule: "same_lowercase_name",
            first_name: "bot",
            last_name: "bot",
            email: "bot#{i}@trap.example",
            params: %{},
            inserted_at: ~U[2026-09-18 12:00:00Z]
          }
        end

      Repo.insert_all(Entry, rows)

      SignupTrap.run(~U[2026-09-21 06:00:00Z])

      assert_received {:email, email}

      assert email.subject =~ "1.234 abgefangene Registrierungen"
      assert email.text_body =~ "934 weitere"
      assert email.html_body =~ "934 weitere"
    end
  end
end
