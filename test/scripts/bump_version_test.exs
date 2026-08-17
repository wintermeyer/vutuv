defmodule Scripts.BumpVersionTest do
  @moduledoc """
  `scripts/bump_version.exs` picks the next version number, and the thing it has
  to get right is not the arithmetic but the **claims**: an open pull request
  holds its number in its own `mix.exs` for hours before it merges, so `main`
  still looks free and two branches pick the same one. That produces no merge
  conflict and no warning (both sides write the same line), so the collision is
  only noticed afterwards, when one number names two changes.

  Not async: each test runs the script in its own temp directory, but they share
  the `PATH` a fake `gh` is put on.
  """
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/bump_version.exs", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "bump_version_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_mix(dir, version) do
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Fake.MixProject do
      def project do
        [app: :fake, version: "#{version}"]
      end
    end
    """)
  end

  # A `gh` that answers the two calls the script makes: the open-PR list, and
  # one mix.exs per PR head. `claims` maps a sha to the version that branch
  # carries. `status` non-zero simulates gh failing (unauthenticated, offline).
  defp fake_gh(dir, claims, status \\ 0) do
    listing =
      claims
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{sha, _version}, i} -> "#{1500 + i}\tbranch-#{i}\t#{sha}" end)

    contents =
      Enum.map_join(claims, "\n", fn {sha, version} ->
        encoded = Base.encode64(~s(  version: "#{version}"))
        ~s(    #{sha}) <> ") echo '#{encoded}';;"
      end)

    path = Path.join([dir, "bin", "gh"])

    File.write!(path, """
    #!/bin/bash
    if [ #{status} -ne 0 ]; then echo "stubbed gh failure" >&2; exit #{status}; fi
    case "$1" in
      pr) printf '%s\\n' '#{listing}' ;;
      api)
        ref="${2##*ref=}"
        case "$ref" in
    #{contents}
          *) echo "no such ref" >&2; exit 1;;
        esac
        ;;
    esac
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp run(dir, level \\ "patch") do
    env = [{"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")}]

    {out, status} =
      System.cmd("elixir", [@script, level], cd: dir, env: env, stderr_to_stdout: true)

    version =
      File.read!(Path.join(dir, "mix.exs")) |> then(&Regex.run(~r/"([\d.]+)"/, &1)) |> Enum.at(1)

    %{output: out, status: status, version: version}
  end

  test "bumps past the number an open PR already claims", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{"sha1" => "7.304.1"})

    result = run(dir)

    assert result.status == 0
    # 7.304.1 is taken, so the patch bump has to land on .2 — bumping from the
    # local file alone would have produced the very collision this prevents.
    assert result.version == "7.304.2"
    assert result.output =~ "already claims 7.304.1"
  end

  test "an equal claim is reported too: that is the silent case", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{"sha1" => "7.304.0"})

    result = run(dir)

    assert result.version == "7.304.1"
    assert result.output =~ "already claims 7.304.0"
  end

  test "a claim below the local number changes nothing", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{"sha1" => "7.300.1"})

    result = run(dir)

    assert result.version == "7.304.1"
    refute result.output =~ "already claims"
  end

  test "minor and major bump from the highest claim as well", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{"sha1" => "7.305.3"})

    assert run(dir, "minor").version == "7.306.0"

    write_mix(dir, "7.304.0")
    assert run(dir, "major").version == "8.0.0"
  end

  # Refusing to bump would block a deploy over a network hiccup, and the
  # fallback is only as wrong as the behaviour before this existed — but it must
  # say so, or a silent fallback reads as "no claims found".
  test "gh failing warns and still bumps from mix.exs", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{"sha1" => "7.304.9"}, 4)

    result = run(dir)

    assert result.status == 0
    assert result.version == "7.304.1"
    assert result.output =~ "could not read the open PRs"
  end

  test "gh missing entirely is the same degraded path", %{dir: dir} do
    write_mix(dir, "7.304.0")

    result = run(dir)

    assert result.status == 0
    assert result.version == "7.304.1"
    assert result.output =~ "could not read the open PRs"
  end

  test "an unknown level fails loudly instead of writing a wrong number", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{})

    result = run(dir, "huge")

    assert result.status == 1
    assert result.version == "7.304.0"
    assert result.output =~ "unknown level"
  end
end
