defmodule Vutuv.Ollama do
  @moduledoc """
  Where this installation's Ollama instance(s) live, and how to talk to them.

  Two callers share this: the AI image moderation
  (`Vutuv.Moderation.Ollama`) and the Arbeitszeugnis analysis
  (`Vutuv.References.Analyst`). They ask very different things of the model,
  but they reach it the same way, and the endpoint rules are the part that
  must not drift between them.

  `:ollama_url` may be a comma-separated **priority list**, e.g. a fast GPU
  box first and a patient CPU instance last. Every instance but the last is
  tried with the short `:ollama_remote_timeout` and skipped on any service
  failure; the last is the fallback of record and gets the caller's full
  timeout. Which instance answered is not interesting to the caller — an
  answer is an answer wherever it came from.

  Tests inject a `plug:` responder through the caller's own Req-options config
  key, so each caller keeps its own stub without seeing the other's.
  """

  @doc """
  The configured instance(s), in priority order.

  A single URL behaves exactly like a one-element list: one endpoint, the
  caller's full timeout.
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
  POSTs `json` to `path` (e.g. `"/api/chat"`) on the first instance that
  answers, and returns `{:ok, body}` or `{:error, {:service, reason}}`.

  Only service-class failures fall through to the next instance: unreachable,
  timed out, or a non-200 status. A 200 is the answer, even a surprising one —
  interpreting it is the caller's job.

  Options:

    * `:timeout` — the receive timeout for the **last** instance in the list
      (the patient fallback).
    * `:remote_timeout` — the budget for every *earlier* instance. Defaults to
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

    try_endpoints(
      urls(),
      path,
      json,
      {timeout, remote},
      req_options,
      {:error, {:service, :no_endpoints}}
    )
  end

  defp try_endpoints([], _path, _json, _timeouts, _req_options, last_error), do: last_error

  defp try_endpoints([url | rest], path, json, {timeout, remote} = timeouts, req_options, _last) do
    receive_timeout = if rest == [], do: timeout, else: remote

    case request(url <> path, json, receive_timeout, req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        try_endpoints(
          rest,
          path,
          json,
          timeouts,
          req_options,
          {:error, {:service, {:http, status}}}
        )

      {:error, reason} ->
        try_endpoints(rest, path, json, timeouts, req_options, {:error, {:service, reason}})
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
