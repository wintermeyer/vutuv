defmodule Vutuv.Notifications.Cronjob do
  @moduledoc false

  import Ecto.Query
  alias Vutuv.Accounts.User
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo

  def send_birthday_reminders do
    users =
      Repo.all(
        from(u in User, where: u.validated? == true, where: u.send_birthday_reminder == true)
      )
      |> Repo.preload([:followees])

    today = Date.utc_today()

    for user <- users do
      todays_users = followees_who_have_birthday(user, today)

      future_users =
        for n <- 1..21 do
          date = Date.add(today, n)
          followees_who_have_birthday(user, date)
        end

      future_users =
        List.flatten(future_users)
        |> Enum.take(5)

      unless Enum.empty?(todays_users) do
        Emailer.birthday_reminder(user, todays_users, future_users)
        |> Vutuv.Mailer.deliver()
      end
    end
  end

  def followees_who_have_birthday(user, date) do
    month = date.month
    day = date.day

    winners =
      for(followee <- user.followees) do
        case followee.birthdate do
          %Date{month: ^month, day: ^day} ->
            followee

          _ ->
            nil
        end
      end

    Enum.reject(winners, fn x -> x == nil end)
  end
end
