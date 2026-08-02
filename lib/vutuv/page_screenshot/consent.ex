defmodule Vutuv.PageScreenshot.Consent do
  @moduledoc """
  The cookie-consent blocker injected into every frame of a capture.

  A link-preview screenshot of a European page is, more often than not, a
  picture of a consent dialog. This wraps `@duckduckgo/autoconsent`: it detects
  the site's consent manager, hides it immediately, and clicks **reject** — it
  never accepts, because consenting to tracking on a member's behalf is not
  ours to do.

  The vendored files (`priv/chrome/autoconsent/`, see the README beside them)
  are copied in by `mix assets.setup`. When they are absent — a checkout that
  never ran it — `injection/0` is `:disabled` and the capture proceeds without
  a blocker, dialogs and all. That is a deliberate fail-open: dismissing a
  dialog is cosmetic, and a shot of the banner beats no shot at all. (The SSRF
  egress control in `Vutuv.PageScreenshot` is a different matter and fails
  closed.)

  It is injected only where a dialog is in the way, which is the link-preview
  paths. `Vutuv.Moderation.EvidenceScreenshot` deliberately does without: that
  capture is a record of what a reported member actually posted, and running a
  third-party script that hides elements and clicks buttons over it — one that
  updates itself with `npm update`, unreviewed — is not what evidence should
  be.

  ## The host side

  The bundle does not run by itself. It asks its host — us — for its config and
  rule set, asks us to evaluate detection snippets in the frame it lives in,
  and reports back what it found and did. `Vutuv.PageScreenshot.Cdp` speaks
  that conversation; this module owns what we say.

  Two details of that protocol are easy to get wrong and fail *silently*, so
  they live in `script/0` with the reason attached.
  """

  # Autoconsent's own defaults are what we want, so this only turns its console
  # logging off — the capture browser's console goes nowhere and every line
  # costs a message. `autoAction: "optOut"` is the one worth stating out loud
  # even though it is the default: reject, never accept.
  @config %{
    enabled: true,
    autoAction: "optOut",
    enablePrehide: true,
    enableCosmeticRules: true,
    enableHeuristicDetection: true,
    logs: %{
      lifecycle: false,
      rulesteps: false,
      detectionsteps: false,
      evals: false,
      errors: false,
      messages: false,
      waits: false
    }
  }

  # The name we register the page->host binding under. Deliberately not
  # `autoconsentSendMessage`: that one is a real function the bundle installs
  # expectations around, and shadowing it with a raw binding is what the shim
  # in `script/0` exists to avoid.
  @binding "__vutuvConsentSend"

  @doc "The binding name the injected script calls to reach us."
  def binding, do: @binding

  @doc """
  Everything needed to inject the blocker, or `:disabled`.

  One value, resolved once, so that "is there a blocker?" and "here it is"
  cannot disagree: asking `File.exists?` and *then* reading the file is two
  answers to one question, and on a half-vendored tree the second one raises —
  turning the documented fail-open into a failed capture. Reading inside the
  same memo means a tree without a usable blocker is simply `:disabled`.

  `script` is the JavaScript evaluated on every new document in every frame.
  Two shims sit in front of the vendored bundle, both fixing an incompatibility
  between how it expects to reach its host and what a raw CDP binding is. Each
  failed silently when it was missing: no error, no dialog dismissed, just a
  capture that looks like autoconsent has no rule for the site.

    * The bundle captures `window.autoconsentSendMessage` at document start,
      which can be *before* the binding is installed; resolving it at call time
      instead makes the ordering stop mattering.

    * A CDP binding takes exactly one string argument, while the bundle passes
      an object (its Playwright host gets JSON serialisation for free from
      `exposeFunction`). Unserialised, the very first call throws
      `Invalid arguments: should be exactly one string` inside the bundle's
      constructor, so `autoconsentReceiveMessage` is never even installed.

  `init_expression` is the whole `Runtime.evaluate` expression answering the
  bundle's `init` message, not just its JSON. Every frame of every capture asks
  for the rule set, and it is a few hundred kilobytes, so building the answer
  per frame would be the most expensive thing in the pipeline by a wide margin.
  """
  def injection do
    cached(dir(), fn ->
      shim = """
      window.autoconsentSendMessage = (message) => window.#{@binding}(JSON.stringify(message));
      """

      %{
        script: shim <> File.read!(bundle_path()),
        init_expression: init_expression()
      }
    end)
  end

  defp init_expression do
    rules = rules_path() |> File.read!() |> Jason.decode!()
    payload = Jason.encode!(%{type: "initResp", config: @config, rules: rules})
    "window.autoconsentReceiveMessage(#{payload})"
  end

  # File reads and a JSON decode of the rule set, done once per node. The
  # vendored files never change under a running release, so a plain cache is
  # enough — no invalidation. Keyed by directory: a test that points
  # `:autoconsent_dir` elsewhere would otherwise be served (and would leave
  # behind) the wrong installation's bundle.
  defp cached(key, fun) do
    term = {__MODULE__, key}

    case :persistent_term.get(term, :none) do
      :none ->
        value = resolve(fun)
        :persistent_term.put(term, value)
        value

      value ->
        value
    end
  end

  # A missing or half-vendored directory is the documented fail-open case, not
  # an error: capture without a blocker rather than not at all.
  defp resolve(fun) do
    fun.()
  rescue
    File.Error -> :disabled
  end

  defp bundle_path, do: Path.join(dir(), "autoconsent.js")
  defp rules_path, do: Path.join(dir(), "rules.json")

  defp dir do
    Application.get_env(:vutuv, :autoconsent_dir) ||
      Application.app_dir(:vutuv, "priv/chrome/autoconsent")
  end
end
