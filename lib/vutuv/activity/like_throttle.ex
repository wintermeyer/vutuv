defmodule Vutuv.Activity.LikeThrottle do
  @moduledoc """
  How loudly the n-th like of one post is announced to its author.

  A post that takes off would otherwise ring the phone once per like, and the
  fiftieth buzz tells the author nothing the tenth did not. So only the first
  `@single_likes` likes are announced one by one; after that only the
  milestones (25, 50, 100, 250, …) are, each as "your post now has N likes";
  and when the like count reaches the member's cap (`:like_notification_cap`,
  a `Vutuv.Prefs` knob) the last announcement says so, and every later like is
  quiet.

  Quiet means **no interruption**: no push, no popup, no bump of the bell. The
  like is still stored and still counted on the post's card on
  /notifications, so nothing is hidden from a member who goes looking.

  The favourites a post collects on other networks count toward the same n,
  because to the author a like is a like.
  """

  @single_likes 10

  # The jumps after the single likes. Past the list the pattern repeats one
  # order of magnitude up (1_000, 2_500, 5_000, 10_000, …), so an uncapped
  # member still hears about a post that keeps growing, just ever more rarely.
  @steps [25, 50, 100, 250, 500]

  @doc """
  The announcement for the `n`-th like when the author's cap is `cap` (an
  integer, or `nil` for no cap):

    * `:single` — announce this like like any other notification
    * `{:milestone, n}` — announce that the post now has `n` likes
    * `{:final, n}` — the same, plus that further likes stay quiet
    * `:quiet` — no interruption at all
  """
  def decide(n, _cap) when n <= @single_likes, do: :single
  def decide(n, cap) when is_integer(cap) and n == cap, do: {:final, n}
  def decide(n, cap) when is_integer(cap) and n > cap, do: :quiet

  def decide(n, _cap) do
    if milestone?(n), do: {:milestone, n}, else: :quiet
  end

  defp milestone?(n) when n in @steps, do: true
  defp milestone?(n) when n >= 1_000, do: rem(n, 10) == 0 and milestone?(div(n, 10))
  defp milestone?(_n), do: false
end
