defmodule Vutuv.Notifications.EmailerConfigTest do
  # The operator identity (From, operator recipient, footer credit) is
  # per-installation configuration, not source code. async: false because the
  # tests swap global application env.
  use Vutuv.DataCase, async: false

  alias Vutuv.Notifications.Emailer

  test "base_email/0 takes its From (and Message-ID domain) from :mailer_from" do
    swap_env(:mailer_from, {"Acme Net", "no-reply@acme.example"})

    email = Emailer.base_email()

    assert email.from == {"Acme Net", "no-reply@acme.example"}
    assert email.headers["Message-ID"] =~ "@acme.example>"
  end

  test "without an override the From stays the vutuv.de default" do
    assert Emailer.base_email().from == {"vutuv", "no-reply@vutuv.de"}
  end

  test "bulk_headers/1 builds the unsubscribe mailto from the configured From" do
    swap_env(:mailer_from, {"Acme Net", "no-reply@acme.example"})

    email = Emailer.base_email() |> Emailer.bulk_headers()

    assert email.headers["List-Unsubscribe"] ==
             "<mailto:no-reply@acme.example?subject=unsubscribe>"
  end

  defp swap_env(key, value) do
    original = Application.fetch_env!(:vutuv, key)
    on_exit(fn -> Application.put_env(:vutuv, key, original) end)
    Application.put_env(:vutuv, key, value)
  end
end
