defmodule Vutuv.Notifications.EmailBounce do
  @moduledoc """
  One recorded failure DSN (see `Vutuv.Notifications.Bounces`). Never built
  from user params - rows are inserted by the bounce parser only.
  """

  use VutuvWeb, :model

  schema "email_bounces" do
    field(:email_value, :string)
    field(:action, :string)
    field(:status, :string)
    field(:raw, :string)

    timestamps(updated_at: false)
  end
end
