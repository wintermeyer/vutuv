defmodule Vutuv.SMTPSink do
  @moduledoc """
  A throwaway SMTP server for tests: accepts one session on an ephemeral port,
  answers the happy path of RFC 5321, and sends the transcript to the test
  process as `{:smtp_session, %{mail_from: _, rcpt_to: [_], body: _}}`.

  It exists because the thing under test is what goes **on the wire** — the
  envelope sender in `MAIL FROM` and the absence of a `Sender:` header in the
  message — and neither is observable from a `%Swoosh.Email{}` struct or from
  the Swoosh test adapter. Deliberately not a mail server: it speaks just
  enough for `:gen_smtp_client` to complete one delivery.
  """

  @doc """
  Starts the sink and returns `{:ok, pid, port}`. The caller (the test process)
  receives the transcript once the session's `DATA` is complete.
  """
  def start_link(test_pid) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept(listen, test_pid) end)

    {:ok, pid, port}
  end

  defp accept(listen, test_pid) do
    {:ok, socket} = :gen_tcp.accept(listen)
    :ok = :gen_tcp.send(socket, "220 sink ESMTP\r\n")
    converse(socket, test_pid, %{mail_from: nil, rcpt_to: [], body: nil})
    :gen_tcp.close(listen)
  end

  defp converse(socket, test_pid, session) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, line} -> handle(String.trim_trailing(line), socket, test_pid, session)
      {:error, _closed} -> :ok
    end
  end

  defp handle("QUIT", socket, _test_pid, _session) do
    :gen_tcp.send(socket, "221 Bye\r\n")
    :gen_tcp.close(socket)
  end

  defp handle("DATA", socket, test_pid, session) do
    :gen_tcp.send(socket, "354 End data with <CR><LF>.<CR><LF>\r\n")
    session = %{session | body: read_data(socket, [])}
    :gen_tcp.send(socket, "250 OK: queued\r\n")
    send(test_pid, {:smtp_session, %{session | rcpt_to: Enum.reverse(session.rcpt_to)}})
    converse(socket, test_pid, session)
  end

  defp handle(line, socket, test_pid, session) do
    session =
      cond do
        # "MAIL FROM:<bounces@vutuv.de>" — the RFC 5321 envelope sender, kept
        # verbatim (angle brackets included) so a test can assert on the exact
        # address the SMTP conversation announced.
        String.starts_with?(line, "MAIL FROM:") ->
          %{session | mail_from: envelope_arg(line, "MAIL FROM:")}

        String.starts_with?(line, "RCPT TO:") ->
          %{session | rcpt_to: [envelope_arg(line, "RCPT TO:") | session.rcpt_to]}

        true ->
          session
      end

    :gen_tcp.send(socket, "250 OK\r\n")
    converse(socket, test_pid, session)
  end

  # The address without the command, and without any ESMTP parameters the
  # client may append ("MAIL FROM:<a@b> SIZE=1234").
  defp envelope_arg(line, command) do
    line
    |> String.replace_prefix(command, "")
    |> String.trim()
    |> String.split(" ", parts: 2)
    |> List.first()
  end

  defp read_data(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, ".\r\n"} -> acc |> Enum.reverse() |> Enum.join()
      {:ok, line} -> read_data(socket, [line | acc])
      {:error, _closed} -> acc |> Enum.reverse() |> Enum.join()
    end
  end
end
