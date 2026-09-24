defmodule Vutuv.Activity.NotificationVisitsTest do
  @moduledoc """
  The looks /notifications draws as lines (`Vutuv.Activity.record_notification_visit/2`).
  """
  use Vutuv.DataCase, async: true

  import Ecto.Query

  alias Vutuv.Activity
  alias Vutuv.Activity.NotificationVisit

  defp visits(user), do: Repo.all(from(v in NotificationVisit, where: v.user_id == ^user.id))

  defp backdate_all(user, minutes) do
    Repo.update_all(from(v in NotificationVisit, where: v.user_id == ^user.id),
      set: [at: DateTime.add(DateTime.utc_now(:second), -minutes, :minute)]
    )
  end

  test "a look is recorded with where it came from" do
    user = insert(:user)
    :ok = Activity.record_notification_visit(user.id, "bell")

    assert [%NotificationVisit{source: "bell"}] = visits(user)
  end

  test "the previous visit is the look before the sitting the member is in" do
    user = insert(:user)
    assert Activity.previous_notification_visit(user.id) == nil

    :ok = Activity.record_notification_visit(user.id, "page")
    backdate_all(user, 240)
    [%NotificationVisit{at: earlier}] = visits(user)

    # Four hours later: the earlier look is the previous one, before and after
    # this sitting records itself, and a reconnect inside it changes nothing.
    assert Activity.previous_notification_visit(user.id) == DateTime.to_naive(earlier)
    :ok = Activity.record_notification_visit(user.id, "page")
    assert Activity.previous_notification_visit(user.id) == DateTime.to_naive(earlier)
  end

  test "looks within one sitting are one line, moved forward, and stay a page visit" do
    user = insert(:user)
    :ok = Activity.record_notification_visit(user.id, "page")
    backdate_all(user, 5)
    :ok = Activity.record_notification_visit(user.id, "bell")

    assert [%NotificationVisit{source: "page", at: at}] = visits(user)
    assert DateTime.diff(DateTime.utc_now(:second), at) < 5
  end

  test "a look after a break is a line of its own" do
    user = insert(:user)
    :ok = Activity.record_notification_visit(user.id, "page")
    backdate_all(user, 240)
    :ok = Activity.record_notification_visit(user.id, "page")

    assert [_, _] = visits(user)
  end

  test "looks older than the retention window are dropped when a new one is written" do
    user = insert(:user)
    :ok = Activity.record_notification_visit(user.id, "page")
    backdate_all(user, 200 * 24 * 60)
    :ok = Activity.record_notification_visit(user.id, "page")

    assert [_] = visits(user)
  end

  test "notification_visits/3 lists a window oldest first on the feed's clock" do
    user = insert(:user)
    :ok = Activity.record_notification_visit(user.id, "page")
    backdate_all(user, 120)
    :ok = Activity.record_notification_visit(user.id, "bell")

    now = NaiveDateTime.utc_now(:second)
    [first, second] = Activity.notification_visits(user.id, NaiveDateTime.add(now, -1, :day), now)

    assert %{source: "page", at: %NaiveDateTime{}} = first
    assert %{source: "bell"} = second
    assert NaiveDateTime.compare(first.at, second.at) == :lt

    assert Activity.notification_visits(
             user.id,
             NaiveDateTime.add(now, -1, :day),
             NaiveDateTime.add(now, -3, :hour)
           ) == []
  end

  test "a nil member records nothing and has no last look" do
    assert :ok = Activity.record_notification_visit(nil, "page")
    assert Activity.previous_notification_visit(nil) == nil
  end
end
