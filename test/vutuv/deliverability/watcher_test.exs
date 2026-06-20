defmodule Vutuv.Deliverability.WatcherTest do
  @moduledoc """
  The log-tailing glue: start at end-of-file (never re-process history), hold a
  partial last line until it completes, and re-read from the top after rotation.
  The heavy lifting (parse, classify, attribute, freeze) is covered by the
  MailLog and Deliverability tests; this drives a real temp file end to end.
  """
  use Vutuv.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Vutuv.Accounts.Email
  alias Vutuv.Deliverability.Watcher
  alias Vutuv.Repo

  @envelope "2026-06-20T10:00:00 bremen2 postfix/qmgr[1]: QID000001: from=<bounces@vutuv.de>, size=1"
  defp bounce_line(addr),
    do:
      "2026-06-20T10:00:01 bremen2 postfix/smtp[2]: QID000001: to=<#{addr}>, relay=mx[1.2.3.4]:25, dsn=5.1.1, status=bounced (550 5.1.1 User unknown)"

  setup do
    path = Path.join(System.tmp_dir!(), "maillog-#{System.unique_integer([:positive])}.log")
    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  defp start_watcher(path, poll_ms \\ 60_000) do
    Application.put_env(:vutuv, Watcher, path: path, poll_ms: poll_ms)
    on_exit(fn -> Application.delete_env(:vutuv, Watcher) end)
    pid = start_supervised!(Watcher)
    Sandbox.allow(Repo, self(), pid)
    pid
  end

  # Trigger one read cycle and block until the watcher has finished it.
  defp tick(pid) do
    send(pid, :poll)
    :sys.get_state(pid)
  end

  defp confirmed_user(address) do
    user = insert(:activated_user)
    insert(:email, user: user, value: address)
    user
  end

  defp reload(address), do: Repo.get_by!(Email, value: address)

  test "init starts at end of file so existing history is not re-processed", %{path: path} do
    File.write!(path, @envelope <> "\n" <> bounce_line("old@example.com") <> "\n")
    Application.put_env(:vutuv, Watcher, path: path, poll_ms: 60_000)
    on_exit(fn -> Application.delete_env(:vutuv, Watcher) end)

    assert {:ok, state} = Watcher.init([])
    assert state.offset == File.stat!(path).size
  end

  test "does not start without a configured path" do
    Application.delete_env(:vutuv, Watcher)
    assert Watcher.init([]) == :ignore
  end

  test "a new vutuv hard bounce deactivates the address", %{path: path} do
    confirmed_user("dead@example.com")
    pid = start_watcher(path)

    File.write!(path, @envelope <> "\n" <> bounce_line("dead@example.com") <> "\n", [:append])
    tick(pid)

    assert reload("dead@example.com").undeliverable_at
  end

  test "a partial trailing line is held until it completes", %{path: path} do
    confirmed_user("dead@example.com")
    pid = start_watcher(path)

    # Write the envelope and the bounce line WITHOUT its trailing newline.
    File.write!(path, @envelope <> "\n" <> bounce_line("dead@example.com"), [:append])
    tick(pid)
    refute reload("dead@example.com").undeliverable_at

    # Completing the line makes it actionable.
    File.write!(path, "\n", [:append])
    tick(pid)
    assert reload("dead@example.com").undeliverable_at
  end

  test "re-reads from the top after the log rotates", %{path: path} do
    confirmed_user("first@example.com")
    confirmed_user("second@example.com")
    pid = start_watcher(path)

    File.write!(path, @envelope <> "\n" <> bounce_line("first@example.com") <> "\n", [:append])
    tick(pid)
    assert reload("first@example.com").undeliverable_at

    # Rotation the logrotate way: rename the old file out of the way and create
    # a fresh one at the same path (a new inode), as the watcher must notice.
    File.rename!(path, path <> ".1")
    on_exit(fn -> File.rm(path <> ".1") end)
    File.write!(path, @envelope <> "\n" <> bounce_line("second@example.com") <> "\n")
    tick(pid)
    assert reload("second@example.com").undeliverable_at
  end

  test "another tenant's bounce on the same relay is ignored", %{path: path} do
    confirmed_user("dead@example.com")
    pid = start_watcher(path)

    foreign = [
      "2026-06-20T10:00:00 bremen2 postfix/qmgr[1]: QIDFOREIGN: from=<noreply@animina.de>, size=1",
      "2026-06-20T10:00:01 bremen2 postfix/smtp[2]: QIDFOREIGN: to=<dead@example.com>, dsn=5.1.1, status=bounced (550 user unknown)"
    ]

    File.write!(path, Enum.join(foreign, "\n") <> "\n", [:append])
    tick(pid)

    refute reload("dead@example.com").undeliverable_at
  end
end
