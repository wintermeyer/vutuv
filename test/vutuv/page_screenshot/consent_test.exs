defmodule Vutuv.PageScreenshot.ConsentTest do
  @moduledoc """
  The consent blocker is what keeps a link preview from being a picture of a
  cookie dialog. Its two shims and its opt-out setting are the parts that fail
  *silently* when they are wrong — no error, just a capture that looks like
  autoconsent has no rule for the site — so they are asserted here rather than
  left to a browser smoke test nobody re-runs.

  Everything here runs against a **fixture** directory rather than the real
  vendored bundle: `mix assets.setup` needs npm, CI runs neither, and a unit
  test has no business depending on 800 KB of third-party artifact. What the
  fixture cannot prove — that the vendoring step is wired into `assets.setup`
  at all — is asserted directly against the alias, at the bottom.

  Not async: these set the global `:autoconsent_dir` env, which
  `Vutuv.PageScreenshot.Cdp` also reads.
  """
  use ExUnit.Case, async: false

  alias Vutuv.PageScreenshot.Consent

  @bundle_marker "/* vendored autoconsent bundle */"

  setup do
    original = Application.fetch_env(:vutuv, :autoconsent_dir)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :autoconsent_dir, was)
        :error -> Application.delete_env(:vutuv, :autoconsent_dir)
      end
    end)

    :ok
  end

  defp dir do
    path = Path.join(System.tmp_dir!(), "consent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    Application.put_env(:vutuv, :autoconsent_dir, path)
    path
  end

  # A stand-in for the vendored files, so the assertions below are about our
  # composition rather than about autoconsent's contents.
  defp vendored do
    path = dir()
    File.write!(Path.join(path, "autoconsent.js"), @bundle_marker)
    File.write!(Path.join(path, "rules.json"), ~s({"autoconsent":[{"name":"Example-CMP"}]}))
    path
  end

  # The init answer is a whole `Runtime.evaluate` expression, so the JSON it
  # carries has to be unwrapped to be asserted on.
  defp init_payload do
    %{init_expression: expression} = Consent.injection()

    expression
    |> String.replace_prefix("window.autoconsentReceiveMessage(", "")
    |> String.replace_suffix(")", "")
    |> Jason.decode!()
  end

  describe "injection/0 availability" do
    test "is disabled when the bundle was never vendored" do
      # A checkout where `mix assets.setup` never ran. Capture must still work
      # (dialogs and all): dismissing one is cosmetic, so this fails OPEN,
      # unlike the SSRF egress control, which fails closed.
      dir()
      assert Consent.injection() == :disabled
    end

    test "is disabled, not an exception, when only half of it is there" do
      File.write!(Path.join(dir(), "autoconsent.js"), "// bundle, but no rules")

      # Asking whether the files exist and *then* reading them is two answers
      # to one question: on a half-vendored tree the read raises, and a
      # documented fail-open turns into a failed capture.
      assert Consent.injection() == :disabled
    end

    test "resolves to script and init answer once both files are there" do
      vendored()
      assert %{script: _script, init_expression: _expression} = Consent.injection()
    end
  end

  describe "the injected script" do
    test "serialises the message the bundle sends us" do
      vendored()

      # A CDP binding takes exactly one *string*; the bundle passes an object,
      # because its Playwright host gets serialisation for free. Unserialised,
      # the first call throws inside the bundle's constructor and
      # `autoconsentReceiveMessage` is never installed at all.
      assert Consent.injection().script =~ "JSON.stringify(message)"
    end

    test "resolves the binding at call time, not at document start" do
      vendored()

      # The bundle captures window.autoconsentSendMessage while the document is
      # still being created, which can be before CDP has installed the binding.
      # Reading `window.<binding>` inside the arrow body defers that lookup.
      [shim | _rest] = String.split(Consent.injection().script, "\n", parts: 2)

      assert shim =~ "window.autoconsentSendMessage = (message) =>"
      assert shim =~ "window.#{Consent.binding()}("
    end

    test "carries the vendored bundle after the shim, not instead of it" do
      vendored()
      script = Consent.injection().script

      assert script =~ @bundle_marker
      assert String.starts_with?(script, "window.autoconsentSendMessage")
    end
  end

  describe "the init answer" do
    test "tells autoconsent to reject, never to accept" do
      vendored()

      # We are answering a consent dialog on a member's behalf. Opting them
      # *in* to tracking is not ours to do, so this is the one setting worth a
      # test even though it matches autoconsent's own default.
      assert init_payload()["config"]["autoAction"] == "optOut"
    end

    test "hides the dialog from the first paint" do
      vendored()

      # The shutter can fall before the opt-out click lands; prehide is what
      # keeps that shot clean anyway.
      assert init_payload()["config"]["enablePrehide"] == true
    end

    test "answers the init message with the vendored rule set" do
      vendored()
      payload = init_payload()

      assert payload["type"] == "initResp"
      assert payload["rules"]["autoconsent"] == [%{"name" => "Example-CMP"}]
    end

    test "is a complete expression, built once rather than per frame" do
      vendored()

      # Every frame of every capture asks for the rule set and it is a few
      # hundred kilobytes; assembling the answer per frame would be the most
      # expensive thing in the pipeline.
      assert Consent.injection().init_expression =~ "window.autoconsentReceiveMessage("
    end
  end

  test "assets.setup vendors the bundle, so a deployed release has one" do
    # The fixture above proves the composition; nothing else proves the files
    # ever arrive. They are gitignored and CI never builds assets, so if this
    # step falls out of the alias every capture silently goes back to
    # photographing consent dialogs, with no test anywhere going red.
    assert "vutuv.autoconsent.vendor" in Mix.Project.config()[:aliases][:"assets.setup"]
  end
end
