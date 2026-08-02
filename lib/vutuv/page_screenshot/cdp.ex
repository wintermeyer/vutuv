defmodule Vutuv.PageScreenshot.Cdp do
  @moduledoc """
  Drives headless Chromium over the DevTools protocol to take one screenshot.

  This replaced `chromium --screenshot <url>`, which could not be kept: that
  one-shot command line runs no extensions and offers no way to inject a
  script, so there is nowhere to put a consent blocker
  (`Vutuv.PageScreenshot.Consent`) — and without one, a large share of captures
  are a picture of a cookie dialog. Everything else about the capture is
  unchanged: the same browser flags, the same SSRF egress proxy, the same
  `timeout` wrapper around the process.

  ## Transport

  Chromium speaks the protocol over `--remote-debugging-pipe`: NUL-terminated
  JSON on file descriptors 3 and 4. A port only ever gets 0 and 1, so it is
  launched through `/bin/sh` with those two duplicated across, and Chromium's
  own stdout and stderr are sent to `/dev/null` in the same breath — its log
  lines share fd 1 otherwise and would corrupt the protocol stream. No
  websocket client, and so no new dependency.

  ## Frames

  A consent dialog usually is not in the page. Both sites this was built
  against serve theirs from a Sourcepoint iframe on another origin, which
  Chromium isolates into a *target of its own*; a session attached to the top
  frame neither sees it nor can script it. So every target is auto-attached as
  it appears, set up the same way, and each frame's requests are answered in
  its own session. Skip that and autoconsent detects nothing at all, which
  reads exactly like it having no rule for the site.

  ## When the shot is taken

  Never later than `@page_deadline_ms` after navigation, so a page whose
  network never goes quiet still yields the image it has rendered (the property
  `chromium --timeout` used to provide). Before that ceiling the wait adapts: a
  page with no consent dialog is shot shortly after load, and one with a dialog
  is shot once autoconsent reports it is finished, plus a moment for the
  dialog's removal to paint. A dialog that is never resolved (a consent-or-pay
  wall offers no reject at all) gives up after `@consent_finish_ms` rather than
  burning the whole budget. Every one of those waits is additionally capped by
  `capture_seconds/0`, so no capture can outlast the OS kill.
  """

  alias Vutuv.PageScreenshot.Consent

  # One request/response round trip. Generous: it covers `Page.captureScreenshot`
  # encoding a full-window PNG.
  @request_timeout_ms 15_000
  # Navigation to shot, whatever has happened in between.
  @page_deadline_ms 20_000
  # After load, how long a page is given to reveal a consent dialog before we
  # conclude it has none.
  @consent_probe_ms 3_000
  # The same wait when no blocker was injected: just long enough for the page
  # to paint what it loaded.
  @settle_ms 300
  # Once a dialog is detected, how long autoconsent gets to finish with it.
  @consent_finish_ms 10_000
  # Between "the dialog is gone" and the shutter, so its removal is painted.
  @paint_grace_ms 800
  # How long a wait may block before re-testing its stop condition. Several of
  # those conditions are about elapsed time rather than an incoming message —
  # "the page loaded and stayed quiet" is the common one — and a page that has
  # gone quiet sends nothing to wake us with, so without a tick the wait would
  # run to the deadline every time and a trivial page would cost the full 20s.
  @tick_ms 100
  # OS-level ceiling for the whole browser run; `timeout` force-kills, so a
  # wedged Chromium cannot outlive the capture as an orphan.
  @capture_seconds 30
  @capture_grace 5

  @doc "The OS-level ceiling for one browser run, in seconds."
  def capture_seconds, do: @capture_seconds

  @doc """
  Captures `url` to `out_path` as a PNG. Returns `:ok` or `{:error, reason}`,
  and never raises: `Vutuv.PageScreenshot` runs it from an unsupervised task.

  `opts[:consent]` injects the cookie-consent blocker. Off by default, because
  a capture that alters the page is not always what the caller wants — see
  `Vutuv.PageScreenshot.Consent` on why moderation evidence does without.
  """
  def capture(bin, args, url, out_path, opts \\ []) do
    case open_port(bin, args) do
      {:ok, port} ->
        try do
          port |> new_state(opts) |> run(url, out_path)
        catch
          # A protocol surprise (a reply shape we do not expect, a decode
          # failure) must not take the caller down with it.
          kind, reason -> {:error, {kind, reason}}
        after
          shutdown(port)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run(state, url, out_path) do
    with {:ok, state} <- open_page(state) do
      state |> navigate(url) |> screenshot(out_path)
    end
  end

  # A page target of our own, attached with `flatten: true` so its messages
  # ride the one pipe under a session id rather than a nested envelope.
  defp open_page(state) do
    with {:ok, %{"targetId" => target}, state} <-
           request(state, "Target.createTarget", %{url: "about:blank"}),
         {:ok, %{"sessionId" => session}, state} <-
           request(state, "Target.attachToTarget", %{targetId: target, flatten: true}) do
      {:ok, setup_session(%{state | session: session}, session)}
    end
  end

  # Everything a freshly attached target needs, in one place, because it runs
  # for the top frame and for every cross-origin iframe alike.
  defp setup_session(state, session) do
    state
    |> notify("Runtime.enable", %{}, session)
    |> notify("Page.enable", %{}, session)
    |> inject_consent(session)
    # Follow this target's own cross-origin children, recursively.
    |> notify(
      "Target.setAutoAttach",
      %{autoAttach: true, waitForDebuggerOnStart: true, flatten: true},
      session
    )
    # Auto-attached targets start paused so the line above lands before they
    # run a single script; this releases them.
    |> notify("Runtime.runIfWaitingForDebugger", %{}, session)
  end

  defp inject_consent(%{injection: :disabled} = state, _session), do: state

  defp inject_consent(state, session) do
    state
    |> notify("Runtime.addBinding", %{name: Consent.binding()}, session)
    |> notify(
      "Page.addScriptToEvaluateOnNewDocument",
      %{source: state.injection.script},
      session
    )
  end

  # There is no failure exit: a browser that died or a deadline that passed is
  # still worth trying to photograph, which is the whole point of the ceiling.
  defp navigate(state, url) do
    state = notify(state, "Page.navigate", %{url: url}, state.session)
    deadline = deadline(state, @page_deadline_ms)
    {_shutter_reason, state} = pump(state, &shutter_open?(&1, deadline), deadline)
    state
  end

  # Whether it is time to take the shot. Returns a reason (truthy) or nil, so
  # it doubles as `pump/3`'s stop condition.
  defp shutter_open?(state, deadline) do
    cond do
      state.exited -> :browser_exited
      now() >= deadline -> :deadline
      true -> consent_settled(state, now())
    end
  end

  # Read top to bottom, these are the states a capture passes through: the
  # blocker has finished with a dialog, or it found one and cannot finish, or
  # the page has loaded and revealed no dialog at all.
  defp consent_settled(%{done_at: done_at}, now) when is_integer(done_at) do
    if now - done_at >= @paint_grace_ms, do: :consent_finished
  end

  defp consent_settled(%{cmp_at: cmp_at}, now) when is_integer(cmp_at) do
    if now - cmp_at >= @consent_finish_ms, do: :consent_gave_up
  end

  defp consent_settled(%{loaded_at: loaded_at} = state, now) when is_integer(loaded_at) do
    if now - loaded_at >= state.probe_ms, do: :no_cmp
  end

  defp consent_settled(_state, _now), do: nil

  defp screenshot(state, out_path) do
    case request(state, "Page.captureScreenshot", %{format: "png"}, state.session) do
      {:ok, %{"data" => data}, _state} -> write(data, out_path)
      {:ok, _other, _state} -> {:error, :no_screenshot_data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(data, out_path) do
    case Base.decode64(data) do
      {:ok, png} -> File.write(out_path, png)
      :error -> {:error, :bad_screenshot_encoding}
    end
  end

  ## Protocol plumbing

  defp new_state(port, opts) do
    injection = if Keyword.get(opts, :consent, false), do: Consent.injection(), else: :disabled

    %{
      port: port,
      # Iodata, never a flat binary: a screenshot reply arrives in 64 KB
      # chunks, and re-concatenating (and re-scanning) the whole accumulation
      # per chunk is quadratic — ~10 MB of copying for a 1 MB image.
      buffer: [],
      next_id: 1,
      # Only the one reply `request/3` is blocked on is kept. Every
      # fire-and-forget setup call is acknowledged too, and holding those would
      # grow a live map for the length of the capture for nothing.
      awaiting: nil,
      reply: nil,
      # CDP request id -> the autoconsent eval it is answering
      evals: %{},
      injection: injection,
      # With no blocker injected there is no dialog conversation to wait for,
      # so the page is shot as soon as it has painted.
      probe_ms: if(injection == :disabled, do: @settle_ms, else: @consent_probe_ms),
      session: nil,
      loaded_at: nil,
      cmp_at: nil,
      done_at: nil,
      exited: nil,
      # No individual wait may outlive the whole capture: four steps each
      # allowed their own timeout would otherwise add up to more than the OS
      # ceiling, and `Vutuv.Ssrf.SocksProxy` sizes its own connection lifetime
      # on `capture_seconds/0` being the truth.
      hard_deadline: now() + @capture_seconds * 1000
    }
  end

  defp deadline(state, budget_ms), do: min(now() + budget_ms, state.hard_deadline)

  # Fire and forget: most of the setup needs no acknowledgement, and waiting on
  # each would serialise a dozen round trips for nothing.
  defp notify(state, method, params, session) do
    {_id, state} = post(state, method, params, session)
    state
  end

  defp request(state, method, params, session \\ nil) do
    {id, state} = post(state, method, params, session)
    deadline = deadline(state, @request_timeout_ms)

    case pump(%{state | awaiting: id, reply: nil}, &settled/1, deadline) do
      {nil, _state} -> {:error, {:timeout, method}}
      {{:exited, code}, _state} -> {:error, {:browser_exited, code}}
      {%{"error" => error}, _state} -> {:error, {method, error}}
      {reply, state} -> {:ok, Map.get(reply, "result", %{}), clear_reply(state)}
    end
  end

  # A browser that has died answers nothing, so waiting out the request timeout
  # would only turn a fast, accurate failure into a slow, vague one.
  defp settled(state) do
    if state.exited, do: {:exited, state.exited}, else: state.reply
  end

  defp post(%{exited: code} = state, _method, _params, _session) when not is_nil(code) do
    {state.next_id, state}
  end

  defp post(state, method, params, session) do
    id = state.next_id

    message =
      %{id: id, method: method, params: params}
      |> maybe_put_session(session)
      |> Jason.encode_to_iodata!()

    Port.command(state.port, [message, 0])
    {id, %{state | next_id: id + 1}}
  end

  defp maybe_put_session(message, nil), do: message
  defp maybe_put_session(message, session), do: Map.put(message, :sessionId, session)

  defp clear_reply(state), do: %{state | awaiting: nil, reply: nil}

  # Reads and dispatches frames until `stop` returns something truthy or the
  # deadline passes. Every wait in this module goes through here, so events
  # keep being handled while a request is outstanding.
  defp pump(state, stop, deadline) do
    case stop.(state) do
      nil -> pump_receive(state, stop, deadline)
      result -> {result, state}
    end
  end

  defp pump_receive(state, stop, deadline) do
    remaining = deadline - now()

    if remaining <= 0 do
      {nil, state}
    else
      port = state.port
      wait = min(remaining, @tick_ms)

      receive do
        {^port, {:data, data}} ->
          state |> consume(data) |> pump(stop, deadline)

        {^port, {:exit_status, code}} ->
          pump(%{state | exited: code}, stop, deadline)
      after
        wait -> if remaining > wait, do: pump(state, stop, deadline), else: {nil, state}
      end
    end
  end

  # The buffer never holds a terminator (anything up to one was already split
  # off), so only the new chunk has to be searched. Until one turns up the read
  # is just appended as iodata and nothing is copied or re-scanned.
  defp consume(state, data) do
    case :binary.match(data, <<0>>) do
      :nomatch ->
        %{state | buffer: [state.buffer, data]}

      _found ->
        {frames, rest} = split_frames(IO.iodata_to_binary([state.buffer, data]))
        Enum.reduce(frames, %{state | buffer: [rest]}, &handle_frame(&2, &1))
    end
  end

  @doc """
  Splits a read buffer into complete protocol frames plus the leftover.

  The pipe transport terminates each JSON message with a NUL byte, and a read
  lands wherever it lands: one read routinely carries several messages and ends
  mid-message. Whatever follows the last NUL is an incomplete frame and has to
  be carried over to the next read rather than parsed.
  """
  def split_frames(buffer) do
    [rest | reversed_frames] = buffer |> :binary.split(<<0>>, [:global]) |> Enum.reverse()
    {Enum.reverse(reversed_frames), rest}
  end

  defp handle_frame(state, frame) do
    case Jason.decode(frame) do
      {:ok, message} -> dispatch(state, message)
      # A frame we cannot read is not worth failing the capture over.
      {:error, _reason} -> state
    end
  end

  defp dispatch(state, %{"id" => id} = message) do
    case Map.pop(state.evals, id) do
      {nil, _evals} -> keep_if_awaited(state, id, message)
      {eval, evals} -> answer_eval(%{state | evals: evals}, eval, message)
    end
  end

  defp dispatch(state, %{"method" => method} = message) do
    handle_event(state, method, message["params"] || %{}, message["sessionId"])
  end

  defp dispatch(state, _message), do: state

  # Only the reply `request/3` is blocked on is worth keeping; the rest are
  # acknowledgements of fire-and-forget setup calls.
  defp keep_if_awaited(%{awaiting: id} = state, id, message), do: %{state | reply: message}
  defp keep_if_awaited(state, _id, _message), do: state

  defp handle_event(state, "Target.attachedToTarget", params, _session) do
    setup_session(state, params["sessionId"])
  end

  defp handle_event(state, "Page.loadEventFired", _params, _session) do
    %{state | loaded_at: state.loaded_at || now()}
  end

  defp handle_event(state, "Runtime.bindingCalled", params, session) do
    if params["name"] == Consent.binding() do
      consent_message(state, params, session)
    else
      state
    end
  end

  defp handle_event(state, _method, _params, _session), do: state

  ## The consent conversation

  defp consent_message(state, params, session) do
    case Jason.decode(params["payload"]) do
      {:ok, message} -> consent_message(state, message, params["executionContextId"], session)
      {:error, _reason} -> state
    end
  end

  # The bundle asks for its config and rules before it will do anything.
  defp consent_message(state, %{"type" => "init"}, context, session) do
    evaluate(state, state.injection.init_expression, context, session)
  end

  # ... and asks us to run its detection snippets in the frame it lives in,
  # because it deliberately holds no eval capability of its own.
  defp consent_message(state, %{"type" => "eval"} = message, context, session) do
    {id, state} =
      post(
        state,
        "Runtime.evaluate",
        %{expression: message["code"], returnByValue: true, awaitPromise: true},
        session
      )

    %{state | evals: Map.put(state.evals, id, {message["id"], context, session})}
  end

  defp consent_message(state, %{"type" => type}, _context, _session)
       when type in ["cmpDetected", "popupFound"] do
    %{state | cmp_at: state.cmp_at || now()}
  end

  defp consent_message(state, %{"type" => type}, _context, _session)
       when type in ["autoconsentDone", "autoconsentError"] do
    %{state | done_at: state.done_at || now() + @paint_grace_ms}
  end

  defp consent_message(state, _message, _context, _session), do: state

  defp answer_eval(state, {eval_id, context, session}, message) do
    value = get_in(message, ["result", "result", "value"])
    payload = Jason.encode!(%{type: "evalResp", id: eval_id, result: value})
    evaluate(state, "window.autoconsentReceiveMessage(#{payload})", context, session)
  end

  # Run an expression in one specific frame. `contextId` is what puts it in the
  # right one — a cross-origin iframe has its own, and answering in the wrong
  # one leaves that frame's rule step waiting forever.
  defp evaluate(state, expression, context, session) do
    notify(state, "Runtime.evaluate", %{expression: expression, contextId: context}, session)
  end

  ## Process lifecycle

  defp open_port(bin, args) do
    {cmd, cmd_args} = command(bin, args)

    {:ok, Port.open({:spawn_executable, cmd}, [:binary, :stream, :exit_status, args: cmd_args])}
  rescue
    # Port.open raises when the binary cannot be spawned; the module contract
    # is a tagged tuple.
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  @doc """
  The command line that launches the browser, split out so the fd plumbing is
  testable without spawning anything.

  `3<&0 4>&1` hands Chromium the protocol pipe on the descriptors it expects,
  and the two `/dev/null` redirections that follow take its own stdio away so
  its log output cannot end up interleaved with protocol frames.
  """
  def command(bin, args) do
    shell = ~s(exec "$0" "$@" 3<&0 4>&1 0</dev/null 1>/dev/null 2>/dev/null)
    # Added here rather than by the caller: the flag and the fd plumbing below
    # are one mechanism, and a capture_args/1 that dropped it would launch a
    # perfectly healthy browser that simply never answers.
    sh_args = ["-c", shell, bin, "--remote-debugging-pipe" | args]

    case System.find_executable("timeout") || System.find_executable("gtimeout") do
      nil ->
        {"/bin/sh", sh_args}

      timeout ->
        {timeout, ["--kill-after=#{@capture_grace}", "#{@capture_seconds}", "/bin/sh"] ++ sh_args}
    end
  end

  # Ask the browser to go, then drop the pipe. Chromium exits on EOF, and the
  # `timeout` wrapper is the backstop if it does not.
  defp shutdown(port) do
    if Port.info(port) do
      Port.command(port, [Jason.encode!(%{id: 0, method: "Browser.close", params: %{}}), 0])
      Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
