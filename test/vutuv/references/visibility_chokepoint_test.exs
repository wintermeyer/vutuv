defmodule Vutuv.References.VisibilityChokepointTest do
  @moduledoc """
  Whether somebody else's employment reference may be shown at all is one rule —
  published, and with any attached document cleared by moderation — and
  `JobReference.visible/1` owns it.

  It was written out three times: the owner, the public show page's read
  (`get_public_job_reference/1`) and `public_references_for/2`, each with its own
  copy of the two `where`s. Meanwhile the two web-layer call sites' comments
  named `public_scope()` as *the* guarantee, which was true of exactly one of
  them. A permission answer that depends on whether the next author remembers to
  copy two clauses is not a permission answer.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.References
  alias Vutuv.References.JobReference

  @owner "lib/vutuv/references/job_reference.ex"

  test "nothing outside the owner spells the visibility rule itself" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          path != @owner,
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          line =~ ~r/document_moderation\s*==\s*"approved"/,
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           "route this through JobReference.visible/1:\n" <> Enum.join(offenders, "\n")
  end

  # And the rule itself still refuses both halves, on every read that carries it.
  test "an unpublished reference is invisible to every public read" do
    user = insert(:activated_user)
    private = insert(:job_reference, user: user, public?: false, title: "Nicht öffentlich")
    public = insert(:job_reference, user: user, public?: true, title: "Öffentlich")

    assert References.get_public_job_reference(public.id)
    refute References.get_public_job_reference(private.id)

    titles = user |> References.public_job_references() |> Enum.map(& &1.title)
    assert "Öffentlich" in titles
    refute "Nicht öffentlich" in titles
  end

  test "a published reference whose document is still in moderation is invisible" do
    user = insert(:activated_user)

    held =
      insert(:job_reference,
        user: user,
        public?: true,
        title: "Wartet auf Prüfung",
        document: "zeugnis.pdf",
        document_moderation: "pending"
      )

    refute References.get_public_job_reference(held.id)
    refute held.id in Enum.map(References.public_job_references(user), & &1.id)
  end

  test "public_scope/0 is visible/1 plus the display order" do
    user = insert(:activated_user)
    insert(:job_reference, user: user, public?: true, issued_on: ~D[2020-01-01], title: "Alt")
    insert(:job_reference, user: user, public?: true, issued_on: ~D[2026-01-01], title: "Neu")

    assert ["Neu", "Alt"] =
             JobReference.public_scope() |> Repo.all() |> Enum.map(& &1.title)
  end
end
