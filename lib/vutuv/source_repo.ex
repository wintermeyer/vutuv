defmodule Vutuv.SourceRepo do
  @moduledoc """
  Where the source of the software running on this installation can be read.

  A per-installation value even though the default is the same everywhere
  (`:source_url`, `SOURCE_URL`): an installation running modified code should
  point at *its* source, because that is what the link claims to be. vutuv is
  MIT, so this is honesty about what is running, not a licence obligation.

  It has one home because it had thirteen: the footer, both API discovery
  documents, the media kit, the two error pages, the developer docs and a flash
  message all wrote `https://github.com/wintermeyer/vutuv` out by hand, so a
  fork could not correct the claim without editing nine files — and the two
  copies that were module attributes made it look settled.

  `issues_url/0` and `new_issue_url/0` are here for the same reason: they are
  where a GitHub repository puts its tracker, and an operator who moves the
  source elsewhere gets to move both with one setting.
  """

  @doc "The repository holding the source of the software running here."
  def url, do: Application.fetch_env!(:vutuv, :source_url)

  @doc "The issue tracker beside that repository."
  def issues_url, do: url() <> "/issues"

  @doc "The \"open a bug report\" entry point of that tracker."
  def new_issue_url, do: issues_url() <> "/new"

  @doc """
  The repository URL without its scheme, for link text that shows the address
  rather than a word ("github.com/wintermeyer/vutuv/issues").
  """
  def issues_label, do: String.replace_prefix(issues_url(), "https://", "")
end
