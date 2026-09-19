defmodule Vutuv.Ads.EnabledEnvTest do
  @moduledoc """
  `ADS_ENABLED`, the switch that decides whether an installation sells ad days
  at all.

  It reads the condition out of `config/runtime.exs` rather than restating it
  here: a copy goes on passing once the real one has drifted, and what is being
  pinned is that only a deliberate `true` starts charging anybody. `runtime.exs`
  is not loaded in the test env, so this is the only place that branch is ever
  exercised before production.

  `async: false` because it writes the real `ADS_ENABLED` environment variable,
  which the SQL sandbox does not roll back; nothing else in the suite reads it
  (the app asks `Application.get_env(:vutuv, :ads_enabled)`, which `config/test.exs`
  sets), so the blast radius is this file.
  """
  use ExUnit.Case, async: false

  setup_all do
    source = File.read!(Path.join([__DIR__, "..", "..", "..", "config", "runtime.exs"]))

    [_, condition] =
      Regex.run(
        ~r/if (System\.get_env\("ADS_ENABLED"\)[^\n]*?) do\n\s*config :vutuv, :ads_enabled, true/,
        source
      )

    on_exit(fn -> System.delete_env("ADS_ENABLED") end)
    %{condition: condition}
  end

  defp switched_on?(condition, value) do
    if value, do: System.put_env("ADS_ENABLED", value), else: System.delete_env("ADS_ENABLED")
    {result, _binding} = Code.eval_string(condition)
    result
  end

  test "the exact word true switches it on", %{condition: condition} do
    assert switched_on?(condition, "true")
  end

  test "anything else leaves it off, which is the safe way round", %{condition: condition} do
    # A switch that starts invoicing members must not read a typo, a shell's
    # `1`, or a shouted YES as consent.
    for value <- [nil, "", "1", "yes", "TRUE", "True", " true", "false"] do
      refute switched_on?(condition, value), "#{inspect(value)} should not enable ads"
    end
  end

  test "the knob is documented, or an operator cannot find it" do
    admins = File.read!(Path.join([__DIR__, "..", "..", "..", "docs", "ADMINS.md"]))
    assert admins =~ "`ADS_ENABLED`"
  end
end
