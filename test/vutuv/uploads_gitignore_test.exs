defmodule Vutuv.UploadsGitignoreTest do
  @moduledoc """
  Member-uploaded files must never reach git. In dev and test
  `config :vutuv, :uploads_dir_prefix` is empty, so every uploader writes into
  the repository working tree (`avatars/`, `qualification_documents/`, …). If a
  tree is not gitignored, a routine `git add -A` after a manual upload smoke
  test commits whatever member files that run produced — which is exactly how
  two members' credential-proof scans landed in the public repository (scan
  finding F21).

  This guards both halves of that: no upload tree is tracked, and every upload
  tree is ignored. When you add an uploader, add its served storage-dir root
  here and to `.gitignore` (the private `originals/` copy is covered by the
  single `/originals` rule, so it needs no per-type entry).
  """
  use ExUnit.Case, async: true

  # The served storage-dir roots of every uploader in `lib/vutuv/uploaders/`,
  # plus the moderation-evidence and AI-moderation quarantine trees. Each is a
  # top-level directory written under `:uploads_dir_prefix` (empty in dev/test).
  @upload_trees ~w(
    avatars
    covers
    post_images
    review_covers
    screenshots
    originals
    moderation_evidence
    quarantine
    qualification_documents
    organization_images
    job_posting_images
  )

  test "no member upload artifact is tracked in git" do
    for tree <- @upload_trees do
      {out, 0} = System.cmd("git", ["ls-files", "--", tree], cd: File.cwd!())

      assert out == "",
             """
             #{tree}/ has files tracked in git:
             #{out}
             Member uploads must never be committed. Remove them with `git rm` \
             and, since git history keeps a copy, purge the affected paths from \
             history before treating the leak as closed.
             """
    end
  end

  test "every upload tree is gitignored" do
    for tree <- @upload_trees do
      probe = tree <> "/probe/file.bin"
      {out, status} = System.cmd("git", ["check-ignore", probe], cd: File.cwd!())

      assert status == 0 and String.trim(out) == probe,
             "#{tree}/ is not gitignored — add `/#{tree}` to .gitignore " <>
               "(uploads land here in dev/test and would be committed by `git add -A`)."
    end
  end
end
