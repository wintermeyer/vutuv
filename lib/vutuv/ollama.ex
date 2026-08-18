defmodule Vutuv.Ollama do
  @moduledoc """
  Where this installation's Ollama instance(s) live, and how to talk to them.

  Several callers share this: the AI image moderation
  (`Vutuv.Moderation.Ollama`), the post translations
  (`Vutuv.Translations.Translator` and `Vutuv.Translations.Detector`) and the
  Arbeitszeugnis analysis (`Vutuv.References.Analyst`). They ask very
  different things of the model, but they reach it the same way, and the
  endpoint rules are the part that must not drift between them.

  `:ollama_url` may be a comma-separated list of instances, e.g. two GPU boxes
  and a patient CPU instance last. It is read two ways at once, and both
  matter:

    * as a **priority list** for one call — the first instance is tried first
      and any service failure falls through to the next, ending at the last
      entry, the fallback of record, which gets the caller's full timeout
      while everyone else is on the short `:ollama_remote_timeout`;
    * as a **pool** for concurrent calls — a call made while another one is
      still running starts on the least busy instance instead of queueing
      behind it. Without that a second GPU never takes work: it is only ever
      reached when the first box *fails*, so on a two-card host one card sits
      at 0% (issue #1573).

  The pool is `concurrency/0` entries deep, **the head of the list**, and the
  default leaves the last entry out of it: that entry is the fallback of
  record, which on vutuv.de and in dev is the machine's own CPU Ollama — a
  box that is in the list to keep the feature alive when the GPU is down, not
  to be given half the work. So a one-GPU-plus-CPU installation behaves
  exactly as it did, and naming a second GPU box is all it takes to use one.

  Ties go to the earlier entry, so a single call at a time always starts on
  the first instance — one caller sees exactly the priority list it saw
  before. Which instance answered is not interesting to the caller: an answer
  is an answer wherever it came from.

  Tests inject a `plug:` responder through the caller's own Req-options config
  key, so each caller keeps its own stub without seeing the other's.
  """

  # In-flight calls per endpoint, so concurrent callers spread over the boxes
  # instead of all queueing on the first one. A plain counter array parked in
  # `:persistent_term`, deliberately with no process behind it: `Vutuv.Release`
  # runs sweeps under `bin/vutuv eval`, which never starts the application
  # supervision tree, and an endpoint pool that only worked under `phx.server`
  # would be the kind of seam nobody remembers.
  @in_flight {__MODULE__, :in_flight}

  @doc """
  The configured instance(s), in priority order.

  A single URL behaves exactly like a one-element list: one endpoint, the
  caller's full timeout, nothing to spread.
  """
  def urls do
    :vutuv
    |> Application.get_env(:ollama_url, "http://localhost:11434")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.trim_trailing(&1, "/"))
  end

  @doc """
  How many instances at the head of `urls/0` are workers — which is both how
  deep the pool goes and how many calls a sweep may have in flight.

  Defaults to every entry but the last, because the last one is the fallback
  of record rather than a worker: `gpu,localhost` is one worker (today's
  behaviour, unchanged), `gpu1,gpu2,localhost` is two, and a lone instance is
  itself. `:ollama_concurrency` (`OLLAMA_CONCURRENCY`) overrides it — set it
  to the number of entries when the list is all GPUs and nothing is being held
  in reserve, or above that when one box can genuinely run two calls at once.
  """
  def concurrency do
    case Application.get_env(:vutuv, :ollama_concurrency) do
      count when is_integer(count) and count > 0 -> count
      _unset -> max(length(urls()) - 1, 1)
    end
  end

  @doc """
  POSTs `json` to `path` (e.g. `"/api/chat"`) on the least busy instance and
  returns `{:ok, body}` or `{:error, {:service, reason}}`. A service failure
  falls through to the remaining instances in priority order.

  Only service-class failures fall through: unreachable, timed out, or a
  non-200 status. A 200 is the answer, even a surprising one — interpreting it
  is the caller's job.

  Options:

    * `:timeout` — the receive timeout for the **last configured** instance
      (the patient fallback of record), wherever in this call's attempt order
      it lands.
    * `:remote_timeout` — the budget for every *other* instance. Defaults to
      the short `:ollama_remote_timeout`, which is right for a job measured in
      seconds and **wrong for one measured in minutes**: an Arbeitszeugnis
      review spends 75 s on prefill alone against a cold model, so the default
      would abandon a perfectly healthy fast instance every single time and
      fall through to the patient one — which on a machine that has no local
      Ollama means the whole call fails with `:econnrefused`. A caller whose
      job is slow everywhere passes its own budget here.
    * `:req_options_key` — the config key holding extra Req options, which is
      how tests inject a `plug:` responder.
  """
  def post(path, json, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_timeout())
    remote = Keyword.get(opts, :remote_timeout, remote_timeout())
    req_options = req_options(Keyword.get(opts, :req_options_key))

    case urls() do
      [] ->
        {:error, {:service, :no_endpoints}}

      urls ->
        counters = counters(urls)
        index = claim(counters, min(concurrency(), length(urls)))

        try do
          urls
          |> attempts(index, timeout, remote)
          |> try_endpoints(path, json, req_options, {:error, {:service, :no_endpoints}})
        after
          :counters.sub(counters, index, 1)
        end
    end
  end

  # This call's endpoints as `{url, receive_timeout}`: the claimed one first,
  # then the rest in configured priority order. The patient budget belongs to
  # the last *configured* entry rather than to the last one tried — it is the
  # instance an operator nominated as the one not to give up on, and rotating
  # the starting point must not hand that role to a GPU box.
  defp attempts(urls, index, timeout, remote) do
    fallback = List.last(urls)
    {before, [claimed | rest]} = Enum.split(urls, index - 1)

    Enum.map([claimed | before ++ rest], fn url ->
      {url, if(url == fallback, do: timeout, else: remote)}
    end)
  end

  defp try_endpoints([], _path, _json, _req_options, last_error), do: last_error

  defp try_endpoints([{url, receive_timeout} | rest], path, json, req_options, _last) do
    case request(url <> path, json, receive_timeout, req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        try_endpoints(rest, path, json, req_options, {:error, {:service, {:http, status}}})

      {:error, reason} ->
        try_endpoints(rest, path, json, req_options, {:error, {:service, reason}})
    end
  end

  defp request(url, json, receive_timeout, req_options) do
    [
      url: url,
      json: json,
      receive_timeout: receive_timeout,
      # A down box must fail fast, not eat the whole budget on TCP connect.
      connect_options: [timeout: 5_000],
      retry: false
    ]
    |> Keyword.merge(req_options)
    |> Req.post()
  end

  # Least outstanding requests over the pool, ties to the earlier entry — so
  # one call at a time is always the priority list, and the Nth concurrent
  # call goes to the box with the least to do. Read-then-add is not atomic:
  # two calls starting in the same microsecond can pick the same instance,
  # which costs nothing but a moment's imbalance and is not worth a
  # serialising process.
  defp claim(counters, pool) do
    index = Enum.min_by(1..pool, &:counters.get(counters, &1))
    :counters.add(counters, index, 1)
    index
  end

  # Keyed by the URL list itself, so an installation that changes
  # `:ollama_url` at runtime (and every test that stubs it) gets a fresh array
  # rather than counts belonging to endpoints that are gone.
  defp counters(urls) do
    case :persistent_term.get(@in_flight, nil) do
      {^urls, counters} ->
        counters

      _stale ->
        counters = :counters.new(length(urls), [])
        :persistent_term.put(@in_flight, {urls, counters})
        counters
    end
  end

  defp req_options(nil), do: []
  defp req_options(key), do: Application.get_env(:vutuv, key, [])

  @doc """
  How long a non-final (fast/remote) instance may take before the next one is
  tried. Generous enough for a GPU box to cold-load a model.
  """
  def remote_timeout, do: Application.get_env(:vutuv, :ollama_remote_timeout, 30_000)

  @doc "The default full timeout for the fallback instance."
  def default_timeout, do: Application.get_env(:vutuv, :ollama_timeout, 120_000)
end
