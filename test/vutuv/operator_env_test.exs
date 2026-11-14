defmodule Vutuv.OperatorEnvTest do
  @moduledoc """
  Who receives the operator notices when an installation never set
  `OPERATOR_EMAIL`.

  The shipped default is vutuv.de's own operator, so another installation that
  skipped the variable mailed its nightly report (with its members' names) to
  vutuv.de and named vutuv.de's operator in its `security.txt`, its NodeInfo
  and its error pages. Off vutuv.de the fallback is now `postmaster@` of the
  installation's own mail domain.

  It evaluates the real `config/runtime.exs` for `:prod`, which is the only
  place that branch runs before production. `async: false` because it writes
  real environment variables (`PHX_HOST`, `MAILER_FROM_ADDRESS`,
  `OPERATOR_EMAIL`, `APPEAL_REPLY_TO`, `DB_PASS`, `SECRET_KEY_BASE`) that the
  sandbox does not roll back; the running app reads none of them after boot.
  """
  use ExUnit.Case, async: false

  @runtime Path.join([__DIR__, "..", "..", "config", "runtime.exs"])
  @vars ~w(PHX_HOST MAILER_FROM_ADDRESS OPERATOR_EMAIL OPERATOR_NAME APPEAL_REPLY_TO DB_PASS SECRET_KEY_BASE)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("DB_PASS", "test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("a", 64))

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)
  end

  defp prod_config(env) do
    Enum.each(env, fn {var, value} -> System.put_env(var, value) end)
    Config.Reader.read!(@runtime, env: :prod, target: :host)[:vutuv]
  end

  test "vutuv.de keeps the defaults from config.exs" do
    for host <- ["vutuv.de", "www.vutuv.de"] do
      config = prod_config(%{"PHX_HOST" => host})
      refute Keyword.has_key?(config, :operator_recipient)
      refute Keyword.has_key?(config, :appeal_reply_to)
    end
  end

  test "another installation without OPERATOR_EMAIL writes to its own postmaster" do
    config =
      prod_config(%{
        "PHX_HOST" => "social.example.org",
        "MAILER_FROM_ADDRESS" => "hi@example.org"
      })

    assert config[:operator_recipient] == {"postmaster@example.org", "postmaster@example.org"}
    assert config[:appeal_reply_to] == "postmaster@example.org"
  end

  test "without a From address it falls back to the host" do
    config = prod_config(%{"PHX_HOST" => "social.example.org"})

    assert config[:operator_recipient] ==
             {"postmaster@social.example.org", "postmaster@social.example.org"}
  end

  test "an explicit OPERATOR_EMAIL wins and also answers appeals" do
    config =
      prod_config(%{"PHX_HOST" => "social.example.org", "OPERATOR_EMAIL" => "ops@example.org"})

    assert config[:operator_recipient] == {"ops@example.org", "ops@example.org"}
    assert config[:appeal_reply_to] == "ops@example.org"
  end
end
